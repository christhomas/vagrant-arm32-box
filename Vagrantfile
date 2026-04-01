# Build VM — boots a Linux VM for running build-linux.sh on macOS.
# Not needed on Linux (CI runs build-linux.sh directly).

Vagrant.configure("2") do |config|
  config.vm.box = "generic/debian12"
  config.vm.box_check_update = false
  config.vm.hostname = "build-vm"

  if Vagrant.has_plugin?("vagrant-notify-forwarder-christhomas")
    config.notify_forwarder.enable = false
  end

  config.vm.provider "qemu" do |qe|
    qe.memory = "4G"
    qe.smp = "2"
    qe.ssh_port = 50026
    qe.ssh_auto_correct = true
  end

  config.vm.usable_port_range = 2800..2900

  config.vm.synced_folder File.expand_path(__dir__), "/build-project", type: "virtiofs"
end
