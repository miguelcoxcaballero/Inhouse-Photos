# Inhouse Photos Server 1.2.14

Publishes verified USB phone-network routes as well as the normal local-network
route. Mobile 3.1.93 can prefer the cable without replacing the account, URL,
certificate, photo library or server containers. Network address changes are
published independently of the manager's backup supervisor.

Settings now has **Preparar USB**. Connect a data cable, enable USB tethering on
Android (or Personal Hotspot and trust the PC on iPhone), and keep the mobile app
open. Windows may need Apple Devices for iPhone. Charging or MTP file transfer
alone does not create the required network. First discovery requires access to
the server's public address; previously verified private addresses are cached.

Preparation requires explicit confirmation and Windows administrator consent.
It binds changes to one currently verified phone adapter's GUID and hardware
identity, excludes virtual adapters and USB Ethernet dongles, and requires a
separate physical PC Internet connection. Only that phone adapter's IPv4/IPv6
default-route acceptance, metric and active exact default routes are changed.
Ethernet/Wi-Fi, DNS, firewall, connected prefixes and photos remain untouched.
Private before/after diagnostics are saved on the PC. No preparation runs at
startup or automatically on cable insertion.

The current PC's Ethernet is negotiated at 100 Mbps. Around 10 MB/s is already
close to that physical limit. Faster Wi-Fi uploads require a working Gigabit
cable/router port; USB speed depends on the phone, cable and tether driver.
The UI reports measured throughput, not a guessed speed from the cable rating.

Validation: desktop self-tests, embedded installer checksum and read-only live
network discovery. Physical USB transfer must be tested with a connected phone;
there was no phone attached to the PC during this release verification.
