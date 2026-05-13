Vagrant.configure("2") do |config|
  config.vm.box = "ubuntu/jammy64"
  config.vm.hostname = "devops"
  config.vm.network "private_network", ip: "192.168.56.10"
  config.vm.provider "virtualbox" do |vb|
    vb.name = "devops"
    vb.memory = 8192
    vb.cpus = 4
  end
  config.vm.synced_folder ".", "/home/vagrant/project", type: "virtualbox"
 
end