# This script is designed to make sure that all required CLI tools for the pipeline are installed and on the system path

sudo chmod -R a+rwx ./*
# Install required tools
wget https://go.dev/dl/go1.23.5.linux-amd64.tar.gz
wget https://github.com/genesis-community/genesis/releases/download/v3.0.13/genesis
wget https://github.com/geofffranks/spruce/releases/download/v1.31.1/spruce-linux-amd64
wget https://github.com/egen/safe/releases/download/v1.8.0/safe-linux-amd64
wget https://github.com/cloudfoundry/credhub-cli/releases/download/2.9.41/credhub-linux-amd64-2.9.41.tgz
wget https://github.com/cloudfoundry/bosh-cli/releases/download/v7.8.6/bosh-cli-7.8.6-linux-amd64

tar -xvf credhub-linux-amd64-2.9.41.tgz

# Set up binaries
sudo mv ./bosh-cli-7.8.6-linux-amd64 /usr/local/bin/bosh
sudo mv ./credhub /bin/credhub
sudo mv ./safe-linux-amd64 /bin/safe
sudo mv ./spruce-linux-amd64 /bin/spruce
sudo mv ./genesis /bin/genesis

chmod u+x ./ci/scripts/compare-release-specs.sh
chmod u+x /usr/local/bin/bosh
chmod u+x /bin/credhub
chmod u+x /bin/safe
chmod u+x /bin/spruce
chmod u+x /bin/genesis

# Install Vault
wget -O - https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install vault

echo $(ls -la /usr/local/bin/bosh)

echo "installed:"
echo "bosh: $(bosh --version)"
echo "credhub: $(credhub --version)"
echo "safe: $(safe --version)"
echo "spruce: $(spruce --version)"
echo "genesis: $(genesis --version)"
echo "vault: $(vault --version)"
