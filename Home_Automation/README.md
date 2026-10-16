<!-- AUTOGEN: website/scripts/project-readmes.mjs -->
# Home Automation

Local-first smart home that keeps working without the internet.

Home Assistant plus the brokers, bridges and NVR that make it shine.

| App | What it does | Platforms | Status |
| --- | --- | --- | --- |
| **Home Assistant** | The open-source smart home hub. 3,000+ integrations. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **Mosquitto** | Lightweight MQTT broker for sensors and devices. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **Zigbee2MQTT** | Use Zigbee devices without vendor hubs. | Proxmox, Linux, TrueNAS | Planned |
| **Node-RED** | Flow-based automations for when YAML isn't enough. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **ESPHome** | Flash ESP32 boards into custom sensors from YAML. | Proxmox, Linux, TrueNAS, Windows, macOS | Planned |
| **Frigate** | NVR with real-time AI object detection for cameras. | Proxmox, Linux, TrueNAS | Planned |

## Pre-wired stack: Smart Home Stack

Home Assistant with MQTT, Zigbee and Node-RED already integrated. Plug in a coordinator and start pairing.

Status: planned. Script: `Home_Automation/<platform>/smart-home-stack.sh`

## Layout

Scripts go in one folder per platform:

```
Home_Automation/
  proxmox/        Proxmox VE
  linux/        Ubuntu Server
  truenas/        TrueNAS SCALE
  windows/        Windows
  macos/        macOS
```

Nothing here yet. See [Media_Stack](../Media_Stack) for a finished project.
