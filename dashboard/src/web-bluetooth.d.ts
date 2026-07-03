declare global {
  interface RequestDeviceOptions {
    filters?: BluetoothLEScanFilter[]
    optionalServices?: BluetoothServiceUUID[]
    acceptAllDevices?: boolean
  }

  interface BluetoothLEScanFilter {
    name?: string
    namePrefix?: string
    services?: BluetoothServiceUUID[]
  }

  type BluetoothServiceUUID = string | number
  type BluetoothCharacteristicUUID = string | number

  interface BluetoothRemoteGATTCharacteristic extends EventTarget {
    readonly value?: DataView
    readValue(): Promise<DataView>
    startNotifications(): Promise<BluetoothRemoteGATTCharacteristic>
    stopNotifications(): Promise<BluetoothRemoteGATTCharacteristic>
    addEventListener(
      type: 'characteristicvaluechanged',
      listener: (event: Event) => void,
    ): void
    removeEventListener(
      type: 'characteristicvaluechanged',
      listener: (event: Event) => void,
    ): void
  }

  interface BluetoothRemoteGATTService {
    getCharacteristic(
      characteristic: BluetoothCharacteristicUUID,
    ): Promise<BluetoothRemoteGATTCharacteristic>
  }

  interface BluetoothRemoteGATTServer {
    readonly connected: boolean
    connect(): Promise<BluetoothRemoteGATTServer>
    disconnect(): void
    getPrimaryService(service: BluetoothServiceUUID): Promise<BluetoothRemoteGATTService>
  }

  interface BluetoothDevice extends EventTarget {
    readonly name?: string
    readonly gatt?: BluetoothRemoteGATTServer
    addEventListener(type: 'gattserverdisconnected', listener: (event: Event) => void): void
    removeEventListener(type: 'gattserverdisconnected', listener: (event: Event) => void): void
  }

  interface Bluetooth {
    requestDevice(options?: RequestDeviceOptions): Promise<BluetoothDevice>
  }

  interface Navigator {
    bluetooth?: Bluetooth
  }
}

export {}
