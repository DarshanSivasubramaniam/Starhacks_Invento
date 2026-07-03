import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var coordinator: AppCoordinator
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var voiceTargetInputManager = VoiceTargetInputManager()
    @StateObject private var resourceMonitor = ResourceMonitor()
    @StateObject private var bleVestManager = BLEVestManager()
    @StateObject private var gpsNavigationManager = GPSNavigationManager()
    @State private var isCameraMirrorModeEnabled = false
    @State private var isFindAndGoTargetCaptureActive = false
    @State private var pendingModeEntryCommand: VestMessage?
    @State private var bleCommandSequence = 0

    private let bleSendTimer = Timer.publish(
        every: AppConfig.BLE.sendTimerIntervalSeconds,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        Group {
            if isCameraMirrorModeEnabled {
                cameraMirrorView
            } else {
                NavigationStack {
                    ScrollView {
                        VStack(spacing: AppConfig.Layout.sectionSpacing) {
                            primaryDashboardCard
                            if coordinator.currentMode == .findAndGo {
                                findAndGoControlCard
                            }
                            if coordinator.currentMode == .gpsNavigation {
                                gpsControlCard
                            }
                            bleConnectionCard
                            diagnosticsCard
                        }
                        .padding(AppConfig.Layout.screenPadding)
                    }
                    .background(AppConfig.Colors.screenBackground.ignoresSafeArea())
                    .toolbar(.hidden, for: .navigationBar)
                }
            }
        }
        .onAppear {
            cameraManager.refreshAuthorizationStatus()
            cameraManager.frameProcessor.objectDetectionManager.setMode(coordinator.currentMode)
            cameraManager.frameProcessor.objectDetectionManager.setRequestedTargetLabel(
                coordinator.requestedFindAndGoTarget
            )
            resourceMonitor.startMonitoring()
            cameraManager.frameProcessor.objectDetectionManager.loadModel()
            cameraManager.frameProcessor.handGestureModeSwitchManager.onModeDetected = { mode in
                coordinator.setMode(mode)
            }
            cameraManager.frameProcessor.handGestureModeSwitchManager.onFindAndGoTargetCaptureGesture = {
                handleFindAndGoTargetCaptureGesture()
            }
            sendModeEntryCommand(for: coordinator.currentMode)
            updateGPSNavigationLifecycle(for: coordinator.currentMode)
        }
        .onDisappear {
            resourceMonitor.stopMonitoring()
            voiceTargetInputManager.stopContinuousListening()
            gpsNavigationManager.stopNavigation()
        }
        .onChange(of: coordinator.currentMode) { _, newMode in
            if newMode != .findAndGo {
                cancelFindAndGoTargetCapture()
            }
            sendModeEntryCommand(for: newMode)
            cameraManager.frameProcessor.objectDetectionManager.setMode(newMode)
            updateGPSNavigationLifecycle(for: newMode)
        }
        .onChange(of: coordinator.requestedFindAndGoTarget) { _, newValue in
            cameraManager.frameProcessor.objectDetectionManager.setRequestedTargetLabel(newValue)
        }
        .onReceive(bleSendTimer) { _ in
            sendLatestBLECommandIfNeeded()
        }
    }

    private var primaryDashboardCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Mode", selection: modeSelection) {
                ForEach(AppCoordinator.Mode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            cameraFeed(
                overlays: selectedOverlayItems,
                height: AppConfig.Layout.dashboardCameraHeight,
                showsBadge: true
            )
            .shadow(color: .black.opacity(0.14), radius: 12, x: 0, y: 8)

            dashboardStatusGrid
            dashboardControlGrid
        }
        .padding(AppConfig.Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dashboardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppConfig.Layout.cardCornerRadius + 6))
    }

    private var dashboardHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("VisionVest Live")
                    .font(.title2.weight(.bold))

                Text(coordinator.currentMode.summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                modeBadge
                statusCapsule(cameraManager.depthStatusText, tint: depthStatusColor)
            }
        }
    }

    private var dashboardStatusGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ],
            spacing: 8
        ) {
            compactMetricTile(
                title: "Target",
                value: currentTargetTitle,
                subtitle: currentTargetSubtitle,
                tint: .blue
            )
            compactMetricTile(
                title: "Direction",
                value: currentDirectionTitle,
                subtitle: currentDirectionSubtitle,
                tint: .indigo
            )
            compactMetricTile(
                title: "Urgency",
                value: currentUrgencyTitle,
                subtitle: currentUrgencySubtitle,
                tint: urgencyTint
            )
            compactMetricTile(
                title: "Confidence",
                value: dashboardConfidenceText,
                subtitle: cameraManager.frameProcessor.objectDetectionManager.targetSelector.selectionStatusText,
                tint: .green
            )
            compactMetricTile(
                title: "Usage",
                value: resourceMonitor.cpuUsageText,
                subtitle: "RAM \(resourceMonitor.memoryUsageText)",
                tint: .orange
            )
            compactMetricTile(
                title: "Vest",
                value: bleVestManager.connectionState.displayText,
                subtitle: bleVestManager.lastSendStatusText,
                tint: bleStatusTint
            )
        }
    }

    private var dashboardControlGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            Button(cameraManager.isSessionRunning ? "Stop Camera" : "Start Camera") {
                if cameraManager.isSessionRunning {
                    cameraManager.stopSession()
                } else {
                    cameraManager.requestPermissionAndStart()
                }
            }
            .buttonStyle(
                CameraActionButtonStyle(
                    backgroundColor: cameraManager.isSessionRunning
                        ? AppConfig.Colors.secondaryButtonBackground
                        : AppConfig.Colors.primaryButtonBackground
                )
            )

            Button(bleVestManager.connectionState == .connected ? "Disconnect Vest" : "Connect Vest") {
                if bleVestManager.connectionState == .connected {
                    bleVestManager.disconnect()
                } else {
                    bleVestManager.startScanning()
                }
            }
            .buttonStyle(CameraActionButtonStyle(backgroundColor: AppConfig.Colors.primaryButtonBackground))
            .disabled(bleVestManager.connectionState == .scanning || bleVestManager.connectionState == .connecting)

        }
    }

    private var dashboardBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(.secondarySystemGroupedBackground),
                Color(.systemBackground)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var headerCard: some View {
        infoCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(AppConfig.Copy.homeTitle)
                            .font(.title2.weight(.bold))

                        Text(AppConfig.Copy.homeSubtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    modeBadge
                }

                Picker("Mode", selection: modeSelection) {
                    ForEach(AppCoordinator.Mode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(coordinator.currentMode.summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                HStack(spacing: AppConfig.Layout.cameraControlSpacing) {
                    Button("Start Camera") {
                        cameraManager.requestPermissionAndStart()
                    }
                    .buttonStyle(
                        CameraActionButtonStyle(backgroundColor: AppConfig.Colors.primaryButtonBackground)
                    )

                    Button("Stop Camera") {
                        cameraManager.stopSession()
                    }
                    .buttonStyle(
                        CameraActionButtonStyle(backgroundColor: AppConfig.Colors.secondaryButtonBackground)
                    )
                }

                Button {
                    isCameraMirrorModeEnabled = true
                } label: {
                    Label("Open Camera Mirror View", systemImage: "display")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    CameraActionButtonStyle(backgroundColor: .black)
                )

                Button {
                    toggleVoiceInput()
                } label: {
                    Label(
                        voiceTargetInputManager.isListening ? "Pause Voice Listening" : "Resume Voice Listening",
                        systemImage: voiceTargetInputManager.isListening ? "stop.circle.fill" : "mic.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(
                    CameraActionButtonStyle(
                        backgroundColor: voiceTargetInputManager.isListening ? .red : AppConfig.Colors.primaryButtonBackground
                    )
                )

                summaryRow("Voice", voiceTargetInputManager.statusText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var cameraMirrorView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()

                if cameraManager.isSessionRunning {
                    ZStack {
                        CameraPreviewView(session: cameraManager.session)
                        DetectionOverlayView(
                            overlays: selectedOverlayItems,
                            selectedTargetID: cameraManager.frameProcessor.objectDetectionManager.targetSelector.selectedTarget?.id
                        )
                    }
                    .frame(
                        width: max(geometry.size.width, geometry.size.height * 16.0 / 9.0),
                        height: geometry.size.height
                    )
                    .background(Color.black)
                    .clipped()
                    .allowsHitTesting(false)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 52, weight: .semibold))
                            .foregroundStyle(AppConfig.Colors.cameraPlaceholderTint)

                        Text("Camera Mirror View")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)

                        Text("Start the camera to show the mirrored feed.")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))

                        Button("Start Camera") {
                            cameraManager.requestPermissionAndStart()
                        }
                        .buttonStyle(
                            CameraActionButtonStyle(backgroundColor: AppConfig.Colors.primaryButtonBackground)
                        )
                        .frame(width: min(320, geometry.size.width - 48))
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Button {
                    exitCameraMirrorMode()
                } label: {
                    Label("Exit", systemImage: "xmark.circle.fill")
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.68))
                        .foregroundStyle(.white)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .contentShape(Capsule())
                .zIndex(10)
                .padding(.top, 18)
                .padding(.trailing, 18)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color.black.ignoresSafeArea())
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                exitCameraMirrorMode()
            }
        }
        .statusBarHidden(true)
    }

    private var cameraCard: some View {
        infoCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Live View")
                        .font(.headline)

                    Spacer()

                    statusCapsule(cameraManager.depthStatusText, tint: depthStatusColor)
                }

                cameraFeed(
                    overlays: selectedOverlayItems,
                    height: AppConfig.Layout.cameraPlaceholderHeight,
                    showsBadge: true
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var findAndGoControlCard: some View {
        infoCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Find & Go Target")
                    .font(.headline)

                TextField("Enter object label, e.g. chair or bottle", text: findAndGoTargetBinding)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 14)
                    .background(AppConfig.Colors.debugPanelBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                HStack(spacing: 10) {
                    Button {
                        handleFindAndGoTargetCaptureGesture()
                    } label: {
                        Label(
                            isFindAndGoTargetCaptureActive ? "Finish Target" : "Record Target",
                            systemImage: isFindAndGoTargetCaptureActive ? "stop.circle.fill" : "mic.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(
                        CameraActionButtonStyle(
                            backgroundColor: isFindAndGoTargetCaptureActive ? .red : AppConfig.Colors.primaryButtonBackground
                        )
                    )

                    Button("Clear") {
                        cancelFindAndGoTargetCapture()
                        coordinator.setRequestedFindAndGoTarget("")
                    }
                    .buttonStyle(
                        CameraActionButtonStyle(backgroundColor: AppConfig.Colors.secondaryButtonBackground)
                    )
                }

                Text("Hand control: show 4 fingers again to start or finish recording the target.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                summaryRow("Speech", voiceTargetInputManager.authorizationStatusText)
                summaryRow("Voice Status", voiceTargetInputManager.statusText)
                summaryRow("Motion", cameraManager.frameProcessor.objectDetectionManager.motionManager.statusText)
                summaryRow("Yaw", cameraManager.frameProcessor.objectDetectionManager.motionManager.currentYawDegreesText)
                summaryRow("Scan", cameraManager.frameProcessor.objectDetectionManager.motionManager.accumulatedRotationDegreesText)
                summaryRow("Bearing", cameraManager.frameProcessor.objectDetectionManager.bearingStatusText)
                summaryRow("Scan Lock", cameraManager.frameProcessor.objectDetectionManager.scanMemoryStatusText)

                if !voiceTargetInputManager.transcriptText.isEmpty {
                    summaryRow("Transcript", voiceTargetInputManager.transcriptText)
                }

                Text(cameraManager.frameProcessor.objectDetectionManager.findAndGoStatusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var gpsControlCard: some View {
        infoCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("GPS Destination")
                    .font(.headline)

                summaryRow("Destination", gpsNavigationManager.destinationText)
                summaryRow("GPS Status", gpsNavigationManager.navigationStatusText)
                summaryRow("Permission", gpsNavigationManager.authorizationStatusText)
                summaryRow("Distance", gpsNavigationManager.distanceText)
                summaryRow("Heading", gpsNavigationManager.headingText)
                summaryRow("Direction", gpsNavigationManager.directionText)

                HStack(spacing: AppConfig.Layout.cameraControlSpacing) {
                    Button("Start GPS") {
                        gpsNavigationManager.startNavigation()
                    }
                    .buttonStyle(
                        CameraActionButtonStyle(backgroundColor: AppConfig.Colors.primaryButtonBackground)
                    )

                    Button("Stop GPS") {
                        gpsNavigationManager.stopNavigation()
                    }
                    .buttonStyle(
                        CameraActionButtonStyle(backgroundColor: AppConfig.Colors.secondaryButtonBackground)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func cameraFeed(
        overlays: [DetectionOverlayItem],
        height: CGFloat,
        showsBadge: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            if cameraManager.isSessionRunning {
                CameraPreviewView(session: cameraManager.session)
                DetectionOverlayView(
                    overlays: overlays,
                    selectedTargetID: cameraManager.frameProcessor.objectDetectionManager.targetSelector.selectedTarget?.id
                )
            } else {
                RoundedRectangle(cornerRadius: AppConfig.Layout.cardCornerRadius)
                    .fill(AppConfig.Colors.cameraPlaceholderBackground)

                VStack {
                    Text(AppConfig.Copy.cameraPlaceholderTitle)
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                .padding()
            }

            if cameraManager.isSessionRunning && showsBadge {
                cameraOverlayBadge
                    .padding(12)
            }
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: AppConfig.Layout.cardCornerRadius))
    }

    private var navigationSummaryCard: some View {
        infoCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Navigation Summary")
                        .font(.headline)

                    Spacer()

                    modeBadge
                }

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 10),
                        GridItem(.flexible(), spacing: 10)
                    ],
                    spacing: 10
                ) {
                    metricTile(
                        title: "Target",
                        value: currentTargetTitle,
                        subtitle: currentTargetSubtitle
                    )
                    metricTile(
                        title: "Direction",
                        value: currentDirectionTitle,
                        subtitle: currentDirectionSubtitle
                    )
                    metricTile(
                        title: "Urgency",
                        value: currentUrgencyTitle,
                        subtitle: currentUrgencySubtitle
                    )
                    metricTile(
                        title: "Model",
                        value: cameraManager.frameProcessor.objectDetectionManager.loadedModelNameText,
                        subtitle: cameraManager.frameProcessor.objectDetectionManager.modelStatusText
                    )
                    metricTile(
                        title: "CPU",
                        value: resourceMonitor.cpuUsageText,
                        subtitle: resourceMonitor.statusText
                    )
                    metricTile(
                        title: "RAM",
                        value: resourceMonitor.memoryUsageText,
                        subtitle: "Device memory in use"
                    )
                }

                if let selectedTarget {
                    Divider()

                    summaryRow("Confidence", String(format: "%.2f", selectedTarget.confidence))
                    summaryRow(
                        "Selection",
                        cameraManager.frameProcessor.objectDetectionManager.targetSelector.selectionStatusText
                    )
                    summaryRow(
                        "Inference",
                        cameraManager.frameProcessor.objectDetectionManager.inferenceStatusText
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var liveCommandCard: some View {
        infoCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Live Command")
                        .font(.headline)

                    Spacer()

                    statusCapsule(
                        cameraManager.frameProcessor.objectDetectionManager.liveUrgencyText,
                        tint: urgencyTint
                    )
                }

                TextEditor(text: .constant(currentLiveCommandJSONText))
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 150)
                    .background(AppConfig.Colors.debugPanelBackground)
                    .clipShape(
                        RoundedRectangle(cornerRadius: AppConfig.Layout.cardCornerRadius)
                    )
                    .disabled(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bleConnectionCard: some View {
        infoCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Vest BLE")
                        .font(.headline)

                    Spacer()

                    statusCapsule(bleVestManager.connectionState.displayText, tint: bleStatusTint)
                }

                HStack(spacing: AppConfig.Layout.cameraControlSpacing) {
                    Button("Connect Vest") {
                        bleVestManager.startScanning()
                    }
                    .buttonStyle(
                        CameraActionButtonStyle(backgroundColor: AppConfig.Colors.primaryButtonBackground)
                    )
                    .disabled(bleVestManager.connectionState == .scanning || bleVestManager.connectionState == .connected)

                    Button("Disconnect") {
                        bleVestManager.disconnect()
                    }
                    .buttonStyle(
                        CameraActionButtonStyle(backgroundColor: AppConfig.Colors.secondaryButtonBackground)
                    )
                    .disabled(bleVestManager.connectionState == .disconnected)
                }

                summaryRow("Peripheral", bleVestManager.connectedPeripheralName)
                summaryRow("BLE Status", bleVestManager.statusText)
                summaryRow("Last Send", bleVestManager.lastSendStatusText)
                summaryRow("Sent Count", bleVestManager.sentCommandCountText)
                Text("Service \(AppConfig.BLE.vestServiceUUID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var diagnosticsCard: some View {
        infoCard {
            DisclosureGroup("Diagnostics") {
                VStack(alignment: .leading, spacing: 12) {
                    summaryRow("Permission", cameraManager.authorizationState.description)
                    summaryRow("Camera", cameraManager.cameraStatusText)
                    summaryRow("Depth", cameraManager.depthStatusText)
                    summaryRow("Frames", cameraManager.frameStatusText)
                    summaryRow("Latest Frame", cameraManager.latestFrameText)
                    summaryRow("Sampled Frames", cameraManager.sampledFrameCountText)
                    summaryRow("Processor", cameraManager.frameProcessor.pipelineStatusText)
                    summaryRow("Last Frame", cameraManager.frameProcessor.lastProcessedFrameText)
                    summaryRow("Last Timestamp", cameraManager.frameProcessor.lastProcessedTimestampText)
                    summaryRow("Inference Speed", cameraManager.frameProcessor.objectDetectionManager.inferencePerformanceText)
                    summaryRow("Depth Fusion", cameraManager.frameProcessor.objectDetectionManager.depthFusionStatusText)
                    summaryRow("Depth Samples", cameraManager.frameProcessor.objectDetectionManager.depthFusionDetailsText)
                    summaryRow("Model Details", cameraManager.frameProcessor.objectDetectionManager.modelDetailsText)
                    summaryRow("CPU", resourceMonitor.cpuUsageText)
                    summaryRow("RAM", resourceMonitor.memoryUsageText)
                    summaryRow("Resource Monitor", resourceMonitor.statusText)

                    TextEditor(text: .constant(debugText))
                        .font(.system(.footnote, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: AppConfig.Layout.debugPanelHeight)
                        .background(AppConfig.Colors.debugPanelBackground)
                        .clipShape(
                            RoundedRectangle(cornerRadius: AppConfig.Layout.cardCornerRadius)
                        )
                        .disabled(true)
                }
                .padding(.top, 12)
            }
            .tint(.primary)
        }
    }

    private var cameraOverlayBadge: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(coordinator.currentMode.displayName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))

            Text(overlayBadgeTitle)
                .font(.headline)
                .foregroundStyle(.white)

            Text(currentUrgencySubtitle)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.black.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var modeSelection: Binding<AppCoordinator.Mode> {
        Binding(
            get: { coordinator.currentMode },
            set: { coordinator.setMode($0) }
        )
    }

    private var findAndGoTargetBinding: Binding<String> {
        Binding(
            get: { coordinator.requestedFindAndGoTarget },
            set: { coordinator.setRequestedFindAndGoTarget($0) }
        )
    }

    private var selectedOverlayItems: [DetectionOverlayItem] {
        if let selectedTarget = cameraManager.frameProcessor.objectDetectionManager.targetSelector.selectedTarget {
            return [selectedTarget]
        }

        return []
    }

    private var selectedTarget: DetectionOverlayItem? {
        cameraManager.frameProcessor.objectDetectionManager.targetSelector.selectedTarget
    }

    private var currentTargetTitle: String {
        if coordinator.currentMode == .gpsNavigation {
            return gpsNavigationManager.destinationText
        }

        if coordinator.currentMode == .findAndGo {
            return coordinator.normalizedRequestedFindAndGoTarget.isEmpty
                ? "None requested"
                : coordinator.normalizedRequestedFindAndGoTarget
        }

        return selectedTarget?.label ?? "None"
    }

    private var currentTargetSubtitle: String {
        if coordinator.currentMode == .gpsNavigation {
            return gpsNavigationManager.distanceText
        }

        if coordinator.currentMode == .findAndGo {
            return cameraManager.frameProcessor.objectDetectionManager.findAndGoStatusText
        }

        return selectedTarget?.distanceMeters.map { "\((Int($0 * 1000))) mm" } ?? "No distance"
    }

    private var currentDirectionTitle: String {
        if coordinator.currentMode == .gpsNavigation,
           !hasHigherPriorityLocalSafetyCommand {
            return gpsNavigationManager.directionText
        }

        return cameraManager.frameProcessor.objectDetectionManager.directionEstimator.currentDirection.displayText
    }

    private var currentDirectionSubtitle: String {
        if coordinator.currentMode == .gpsNavigation,
           !hasHigherPriorityLocalSafetyCommand {
            return gpsNavigationManager.navigationStatusText
        }

        return cameraManager.frameProcessor.objectDetectionManager.decisionSmoother.smoothingStatusText
    }

    private var currentUrgencyTitle: String {
        if coordinator.currentMode == .gpsNavigation,
           !hasHigherPriorityLocalSafetyCommand,
           gpsNavigationManager.latestCommand != nil {
            return "GPS"
        }

        return cameraManager.frameProcessor.objectDetectionManager.liveUrgencyText
    }

    private var currentUrgencySubtitle: String {
        if coordinator.currentMode == .gpsNavigation,
           !hasHigherPriorityLocalSafetyCommand {
            return gpsNavigationManager.navigationStatusText
        }

        return cameraManager.frameProcessor.objectDetectionManager.liveCommandStatusText
    }

    private var currentLiveCommandJSONText: String {
        currentOutgoingCommand.map(makePrettyJSONString) ?? "No live command JSON"
    }

    private var dashboardConfidenceText: String {
        guard let selectedTarget else {
            return "--"
        }

        return "\(Int((selectedTarget.confidence * 100).rounded()))%"
    }

    private var currentOutgoingCommand: VestMessage? {
        if let pendingModeEntryCommand {
            return pendingModeEntryCommand
        }

        let localCommand = cameraManager.frameProcessor.objectDetectionManager.latestLiveCommand

        guard coordinator.currentMode == .gpsNavigation else {
            return localCommand
        }

        if let localCommand,
           localCommand.priority > AppConfig.GPS.commandPriority {
            return localCommand
        }

        return gpsNavigationManager.latestCommand ?? localCommand
    }

    private var hasHigherPriorityLocalSafetyCommand: Bool {
        guard coordinator.currentMode == .gpsNavigation,
              let localCommand = cameraManager.frameProcessor.objectDetectionManager.latestLiveCommand else {
            return false
        }

        return localCommand.priority > AppConfig.GPS.commandPriority
    }

    private var overlayBadgeTitle: String {
        if coordinator.currentMode == .gpsNavigation,
           !hasHigherPriorityLocalSafetyCommand {
            return gpsNavigationManager.directionText
        }

        if let selectedTarget {
            return selectedTarget.label
        }

        if coordinator.currentMode == .findAndGo,
           !coordinator.normalizedRequestedFindAndGoTarget.isEmpty {
            return coordinator.normalizedRequestedFindAndGoTarget
        }

        return "No target"
    }

    private var depthStatusColor: Color {
        cameraManager.depthStatusText.contains("active") ? .green : .orange
    }

    private var urgencyTint: Color {
        switch currentUrgencyTitle.lowercased() {
        case "gps":
            return .blue
        case "search":
            return .blue
        case "stop":
            return .red
        case "high":
            return .orange
        case "medium":
            return .yellow
        case "low":
            return .green
        default:
            return .gray
        }
    }

    private var bleStatusTint: Color {
        switch bleVestManager.connectionState {
        case .connected:
            return .green
        case .scanning, .connecting:
            return .blue
        case .failed, .unavailable:
            return .red
        case .disconnected:
            return .gray
        }
    }

    private var modeBadge: some View {
        Text(coordinator.currentMode.displayName)
            .font(.headline)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(AppConfig.Colors.modeBadgeBackground)
            .clipShape(Capsule())
    }

    private var debugText: String {
        [
            coordinator.debugSummary,
            "",
            "camera.permission=\(cameraManager.authorizationState.description)",
            "camera.status=\(cameraManager.cameraStatusText)",
            "camera.depth=\(cameraManager.depthStatusText)",
            "camera.frames=\(cameraManager.frameStatusText)",
            "device.cpu=\(resourceMonitor.cpuUsageText)",
            "device.ram=\(resourceMonitor.memoryUsageText)",
            "device.monitor=\(resourceMonitor.statusText)",
            "camera.sampledFrames=\(cameraManager.sampledFrameCountText)",
            "detector.status=\(cameraManager.frameProcessor.objectDetectionManager.modelStatusText)",
            "detector.model=\(cameraManager.frameProcessor.objectDetectionManager.loadedModelNameText)",
            "detector.details=\(cameraManager.frameProcessor.objectDetectionManager.modelDetailsText)",
            "detector.inference=\(cameraManager.frameProcessor.objectDetectionManager.inferenceStatusText)",
            "detector.performance=\(cameraManager.frameProcessor.objectDetectionManager.inferencePerformanceText)",
            "detector.count=\(cameraManager.frameProcessor.objectDetectionManager.detectionCountText)",
            "detector.overlays=\(cameraManager.frameProcessor.objectDetectionManager.detectionOverlays.count)",
            "depth.fusion=\(cameraManager.frameProcessor.objectDetectionManager.depthFusionStatusText)",
            "depth.samples=\(cameraManager.frameProcessor.objectDetectionManager.depthFusionDetailsText)",
            "findAndGo.state=\(cameraManager.frameProcessor.objectDetectionManager.findAndGoState.rawValue)",
            "findAndGo.status=\(cameraManager.frameProcessor.objectDetectionManager.findAndGoStatusText)",
            "findAndGo.bearing=\(cameraManager.frameProcessor.objectDetectionManager.bearingStatusText)",
            "findAndGo.scanMemory=\(cameraManager.frameProcessor.objectDetectionManager.scanMemoryStatusText)",
            "findAndGo.scan=\(cameraManager.frameProcessor.objectDetectionManager.motionManager.accumulatedRotationDegreesText)",
            "findAndGo.fullScan=\(cameraManager.frameProcessor.objectDetectionManager.motionManager.hasCompletedFullScan)",
            "motion.status=\(cameraManager.frameProcessor.objectDetectionManager.motionManager.statusText)",
            "motion.yaw=\(cameraManager.frameProcessor.objectDetectionManager.motionManager.currentYawDegreesText)",
            "selector.status=\(cameraManager.frameProcessor.objectDetectionManager.targetSelector.selectionStatusText)",
            "direction.current=\(cameraManager.frameProcessor.objectDetectionManager.directionEstimator.currentDirection.rawValue)",
            "direction.status=\(cameraManager.frameProcessor.objectDetectionManager.directionEstimator.directionStatusText)",
            "smoother.direction=\(cameraManager.frameProcessor.objectDetectionManager.decisionSmoother.smoothedDirection.rawValue)",
            "smoother.status=\(cameraManager.frameProcessor.objectDetectionManager.decisionSmoother.smoothingStatusText)",
            "command.status=\(cameraManager.frameProcessor.objectDetectionManager.liveCommandStatusText)",
            "command.urgency=\(cameraManager.frameProcessor.objectDetectionManager.liveUrgencyText)",
            "gps.destination=\(gpsNavigationManager.destinationText)",
            "gps.status=\(gpsNavigationManager.navigationStatusText)",
            "gps.permission=\(gpsNavigationManager.authorizationStatusText)",
            "gps.distance=\(gpsNavigationManager.distanceText)",
            "gps.heading=\(gpsNavigationManager.headingText)",
            "gps.direction=\(gpsNavigationManager.directionText)",
            "ble.state=\(bleVestManager.connectionState.rawValue)",
            "ble.status=\(bleVestManager.statusText)",
            "ble.lastSend=\(bleVestManager.lastSendStatusText)",
            "processor.lastFrame=\(cameraManager.frameProcessor.lastProcessedFrameText)",
            "processor.lastTimestamp=\(cameraManager.frameProcessor.lastProcessedTimestampText)",
            "processor.callback=\(cameraManager.frameProcessor.placeholderCallbackText)"
        ].joined(separator: "\n")
    }

    private func sendLatestBLECommandIfNeeded() {
        if let pendingModeEntryCommand {
            sendBLECommand(pendingModeEntryCommand, bypassRateLimit: true)
            return
        }

        guard let commandToSend = currentOutgoingCommand else {
            return
        }

        sendBLECommand(commandToSend)
    }

    private func exitCameraMirrorMode() {
        isCameraMirrorModeEnabled = false
    }

    private func updateGPSNavigationLifecycle(for mode: AppCoordinator.Mode) {
        if mode == .gpsNavigation {
            gpsNavigationManager.startNavigation()
        } else {
            gpsNavigationManager.stopNavigation()
        }
    }

    private func sendModeEntryCommand(for mode: AppCoordinator.Mode) {
        switch mode {
        case .awareness:
            pendingModeEntryCommand = makeNeutralModeEntryMessage(mode: "awareness")
        case .findAndGo:
            pendingModeEntryCommand = makeNeutralModeEntryMessage(mode: "find_search")
        case .gpsNavigation:
            pendingModeEntryCommand = makeNeutralModeEntryMessage(mode: "gps_nav")
        }

        if let modeEntryCommand = pendingModeEntryCommand {
            for _ in 0..<3 {
                sendBLECommand(modeEntryCommand, bypassRateLimit: true)
            }
        }
    }

    @discardableResult
    private func sendBLECommand(_ command: VestMessage, bypassRateLimit: Bool = false) -> Bool {
        bleCommandSequence += 1
        let sequencedCommand = command.withSequence(bleCommandSequence)
        let didSend = bleVestManager.send(
            message: sequencedCommand,
            bypassRateLimit: bypassRateLimit
        )

        if didSend, pendingModeEntryCommand?.mode == command.mode {
            pendingModeEntryCommand = nil
        }

        return didSend
    }

    private func handleFindAndGoTargetCaptureGesture() {
        guard coordinator.currentMode == .findAndGo else {
            return
        }

        if isFindAndGoTargetCaptureActive {
            finishFindAndGoTargetCapture()
        } else {
            startFindAndGoTargetCapture()
        }
    }

    private func startFindAndGoTargetCapture() {
        coordinator.setRequestedFindAndGoTarget("")
        isFindAndGoTargetCaptureActive = true
        voiceTargetInputManager.startContinuousListening(
            onResolvedTarget: { resolvedTarget in
                coordinator.setRequestedFindAndGoTarget(resolvedTarget)
            },
            onResolvedMode: { _ in
            }
        )
    }

    private func finishFindAndGoTargetCapture() {
        let resolvedTarget = voiceTargetInputManager.resolvedTargetText
        let transcriptTarget = AppConfig.ObjectDetection.resolvedTargetLabel(
            from: voiceTargetInputManager.transcriptText
        )
        let target = AppCoordinator.normalizeTargetLabel(
            resolvedTarget.isEmpty ? (transcriptTarget ?? "") : resolvedTarget
        )

        voiceTargetInputManager.stopContinuousListening()
        isFindAndGoTargetCaptureActive = false

        guard !target.isEmpty else {
            return
        }

        coordinator.setRequestedFindAndGoTarget(target)
    }

    private func cancelFindAndGoTargetCapture() {
        if isFindAndGoTargetCaptureActive || voiceTargetInputManager.isListening {
            voiceTargetInputManager.stopContinuousListening()
        }
        isFindAndGoTargetCaptureActive = false
    }

    private func toggleVoiceInput() {
        voiceTargetInputManager.toggleListening(
            onResolvedTarget: { resolvedTarget in
                coordinator.setRequestedFindAndGoTarget(resolvedTarget)
            },
            onResolvedMode: { _ in
            }
        )
    }

    private func metricTile(title: String, value: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.headline)
                .lineLimit(2)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .leading)
        .padding(12)
        .background(AppConfig.Colors.debugPanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func compactMetricTile(title: String, value: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
        .padding(10)
        .background(.thinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(tint.opacity(0.16), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline.weight(.semibold))

            Spacer()

            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func statusCapsule(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.14))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }

    private func infoCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(AppConfig.Layout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppConfig.Colors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppConfig.Layout.cardCornerRadius))
    }
}

private struct CameraActionButtonStyle: ButtonStyle {
    let backgroundColor: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(backgroundColor.opacity(configuration.isPressed ? 0.75 : 1))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: AppConfig.Layout.cardCornerRadius))
    }
}

#Preview {
    ContentView(coordinator: AppCoordinator())
}
