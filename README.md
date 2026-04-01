# vagrant-arm32-box

Debian Bookworm ARM32 (armhf) Vagrant box for QEMU.

A clean Debian system built via debootstrap — no Raspberry Pi packages or
firmware. ARM32 emulation via TCG software emulation on any host architecture.

## Prerequisites

```bash
vagrant plugin install vagrant-qemu-christhomas
vagrant plugin install vagrant-notify-forwarder-christhomas
```

## Quick start

```bash
vagrant box add christhomas/vagrant-arm32-box \
  https://github.com/christhomas/vagrant-arm32-box/releases/download/v1.0.0/debian-arm32.box
```

Create a `Vagrantfile`:

```ruby
Vagrant.configure("2") do |config|
  config.vm.box = "christhomas/vagrant-arm32-box"
  config.vm.box_architecture = "arm"
  config.vm.box_check_update = false
  config.vm.synced_folder ".", "/vagrant", type: "virtiofs"
end
```

```bash
vagrant up
vagrant ssh
```

## What's in the box

| Feature | Details |
|---------|---------|
| **Base** | Debian Bookworm (armhf) via debootstrap |
| **Boot kernel** | Debian armmp-lpae (external via `-kernel`/`-initrd`) |
| **Emulation** | TCG software emulation (ARM32 on any host) |
| **Shared folders** | virtiofs with UID mapping |
| **Disk expansion** | growroot service on first boot (set size via `qe.disk_resize`) |
| **User** | `vagrant` (UID 1000) |

## Building from source

On macOS (boots a build VM automatically):
```bash
./build-box.sh
```

On Linux (runs directly):
```bash
sudo ./build-linux.sh
```

The build uses debootstrap to create a fresh Debian armhf rootfs from scratch.

## Testing

```bash
cd test/
vagrant up
./test-virtiofs.sh
```

## License

[MIT](LICENSE)
