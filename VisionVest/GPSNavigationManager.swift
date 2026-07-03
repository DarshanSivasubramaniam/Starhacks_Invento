import Combine
import CoreLocation
import Foundation

final class GPSNavigationManager: NSObject, ObservableObject {
    struct Destination {
        let name: String
        let coordinate: CLLocationCoordinate2D
    }

    @Published private(set) var authorizationStatusText = "GPS idle"
    @Published private(set) var navigationStatusText = "GPS not started"
    @Published private(set) var destinationText = "Lawson Building"
    @Published private(set) var distanceText = "No GPS distance"
    @Published private(set) var headingText = "No heading"
    @Published private(set) var directionText = DirectionEstimator.Direction.none.displayText
    @Published private(set) var latestCommand: VestMessage?
    @Published private(set) var liveCommandJSONText = "No GPS command JSON"

    private let locationManager = CLLocationManager()
    private let destination = Destination(
        name: "Lawson Building",
        coordinate: CLLocationCoordinate2D(
            latitude: AppConfig.GPS.lawsonLatitude,
            longitude: AppConfig.GPS.lawsonLongitude
        )
    )

    private var currentLocation: CLLocation?
    private var currentHeadingDegrees: CLLocationDirection?
    private var commandSequence = 0

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager.distanceFilter = 1
        locationManager.headingFilter = 5
        locationManager.activityType = .fitness
    }

    func startNavigation() {
        destinationText = destination.name

        guard CLLocationManager.locationServicesEnabled() else {
            authorizationStatusText = "Location services disabled"
            navigationStatusText = "Enable Location Services in Settings"
            clearCommand()
            return
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            authorizationStatusText = "Requesting GPS permission"
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            authorizationStatusText = "GPS authorized"
            startLocationUpdates()
        case .denied, .restricted:
            authorizationStatusText = "GPS denied"
            navigationStatusText = "Enable location access in Settings"
            clearCommand()
        @unknown default:
            authorizationStatusText = "GPS authorization unknown"
            clearCommand()
        }
    }

    func stopNavigation() {
        locationManager.stopUpdatingLocation()
        locationManager.stopUpdatingHeading()
        navigationStatusText = "GPS stopped"
        clearCommand()
    }

    private func startLocationUpdates() {
        locationManager.startUpdatingLocation()

        if CLLocationManager.headingAvailable() {
            locationManager.startUpdatingHeading()
            headingText = "Waiting for heading"
        } else {
            headingText = "Heading unavailable"
        }

        navigationStatusText = "Navigating to \(destination.name)"
        updateGuidance()
    }

    private func updateGuidance() {
        guard let currentLocation else {
            navigationStatusText = "Waiting for GPS location"
            clearCommand()
            return
        }

        let destinationLocation = CLLocation(
            latitude: destination.coordinate.latitude,
            longitude: destination.coordinate.longitude
        )
        let distanceMeters = currentLocation.distance(from: destinationLocation)
        distanceText = "\(Int(distanceMeters)) m"

        guard distanceMeters > AppConfig.GPS.arrivalDistanceMeters else {
            navigationStatusText = "Arrived at \(destination.name)"
            directionText = DirectionEstimator.Direction.none.displayText
            clearCommand()
            return
        }

        guard let currentHeadingDegrees else {
            navigationStatusText = "Waiting for compass heading"
            clearCommand()
            return
        }

        let bearingDegrees = bearingDegrees(
            from: currentLocation.coordinate,
            to: destination.coordinate
        )
        let deltaDegrees = normalizedDegrees(currentHeadingDegrees - bearingDegrees)
        let direction = DirectionEstimator.direction(forBearingDeltaDegrees: deltaDegrees)

        commandSequence += 1
        let command = makeGPSNavigationMessage(
            direction: direction,
            distanceMeters: distanceMeters,
            seq: commandSequence
        )

        latestCommand = command
        liveCommandJSONText = makePrettyJSONString(from: command)
        directionText = direction.displayText
        navigationStatusText = "GPS \(direction.displayText) to \(destination.name)"
    }

    private func clearCommand() {
        latestCommand = nil
        liveCommandJSONText = "No GPS command JSON"
    }

    private func bearingDegrees(
        from startCoordinate: CLLocationCoordinate2D,
        to endCoordinate: CLLocationCoordinate2D
    ) -> CLLocationDirection {
        let startLatitude = startCoordinate.latitude * .pi / 180
        let startLongitude = startCoordinate.longitude * .pi / 180
        let endLatitude = endCoordinate.latitude * .pi / 180
        let endLongitude = endCoordinate.longitude * .pi / 180
        let longitudeDelta = endLongitude - startLongitude

        let y = sin(longitudeDelta) * cos(endLatitude)
        let x = cos(startLatitude) * sin(endLatitude)
            - sin(startLatitude) * cos(endLatitude) * cos(longitudeDelta)
        let bearing = atan2(y, x) * 180 / .pi

        return bearing < 0 ? bearing + 360 : bearing
    }

    private func normalizedDegrees(_ degrees: CLLocationDirection) -> CLLocationDirection {
        var normalizedDegrees = degrees

        while normalizedDegrees <= -180 {
            normalizedDegrees += 360
        }

        while normalizedDegrees > 180 {
            normalizedDegrees -= 360
        }

        return normalizedDegrees
    }
}

extension GPSNavigationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            authorizationStatusText = "GPS authorized"
            startLocationUpdates()
        case .notDetermined:
            authorizationStatusText = "GPS permission not requested"
        case .denied, .restricted:
            authorizationStatusText = "GPS denied"
            navigationStatusText = "Enable location access in Settings"
            clearCommand()
        @unknown default:
            authorizationStatusText = "GPS authorization unknown"
            clearCommand()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else {
            return
        }

        currentLocation = location
        updateGuidance()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let heading = newHeading.trueHeading > 0 ? newHeading.trueHeading : newHeading.magneticHeading

        guard heading >= 0 else {
            headingText = "Heading invalid"
            return
        }

        currentHeadingDegrees = heading
        headingText = "\(Int(heading))°"
        updateGuidance()
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        navigationStatusText = "GPS failed: \(error.localizedDescription)"
        clearCommand()
    }
}
