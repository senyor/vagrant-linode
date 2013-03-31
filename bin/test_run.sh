function run_test_for {
  cp Vagrantfile.$1 Vagrantfile
  vagrant up --provider=digital_ocean
  vagrant up
  vagrant provision
  vagrant rebuild
  vagrant destroy
  vagrant destroy
}

set -e

cd test
run_test_for centos
run_test_for ubuntu
