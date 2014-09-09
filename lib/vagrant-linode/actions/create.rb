require 'vagrant-linode/helpers/client'

module VagrantPlugins
  module Linode
    module Actions
      class Create
        include Helpers::Client
        include Vagrant::Util::Retryable

        def initialize(app, env)
          @app = app
          @machine = env[:machine]
          @client = client
          @logger = Log4r::Logger.new('vagrant::linode::create')
        end

        def call(env)
          ssh_key_id = [env[:ssh_key_id]]

          if @machine.provider_config.distribution
            distributions = @client.avail.distributions
            distribution = distributions.find { |d| d.label == @machine.provider_config.distribution }
	    distribution_id = distribution.distributionid || nil # @todo throw if not found
          else
            distribution_id = @machine.provider_config.distributionid
          end

          if @machine.provider_config.datacenter
            datacenters = @client.avail.datacenters
            datacenter = datacenters.find { |d| d.abbr == @machine.provider_config.datacenter }
	    datacenter_id = datacenter.datacenterid || nil # @todo throw if not found
	  else
            datacenter_id = @machine.provider_config.datacenterid
          end

          if @machine.provider_config.plan
            plans = @client.avail.linodeplans
	    plan = plans.find { |p| p.label == @machine.provider_config.plan }
	    plan_id = plan.planid || nil # @todo throw if not found
          else
            plan_id = @machine.provider_config.planid
          end

          env[:ui].info I18n.t('vagrant_linode.info.creating')

          # submit new linode request
          result = @client.linode.create(
            :planid => @machine.provider_config.planid,
            :datacenterid => @machine.provider_config.datacenterid,
            :paymentterm => @machine.provider_config.paymentterm || 1
          );
          env[:ui].info I18n.t('vagrant_linode.info.created', { :linodeid => result['linodeid'] })

          sleep 1 until ! @client.linode.job.list(:linodeid => result['linodeid'], :jobid => result['jobid']).length

          if distribution_id
            disk = @client.linode.disk.createfromdistribution(
              :linodeid => result.linodeid,
              :distributionid => distribution_id,
              :label => 'Vagrant Disk Distribution ' + distribution_id + ' Linode ' + result.linodeid,
              :type => 'ext4',
              :size => 1024,
              :rootSSHKey => ssh_key_id
            )
          elsif image_id
            disk = @client.linode.disk.createfromimage(
              :linodeid => result.linodeid,
              :imageid => image_id,
              :size => 1024,
              :rootSSHKey => ssh_key_id
            )
          end

          config = @client.linode.config.create(
            :linodeid => result['linodeid'],
            :label => 'Config',
            :disklist => "#{disk['diskid']}"
          )

	  if @machine.provider_config.private_networking
	    private_network = @client.linode.ip.addprivate :linodeid => result['linodeid']
	  end

          result = @client.linode.update(
            :linodeid => result['linodeid'],
            :label => @machine.config.vm.hostname || @machine.name
          )

          env[:ui].info I18n.t('vagrant_linode.info.booting', {
	    :linodeid => result['linodeid']
	  })
          sleep 1 until ! @client.linode.job.list(:linodeid => result['linodeid'], :jobid => result['jobid']).length

          # assign the machine id for reference in other commands
          @machine.id = result['linodeid'].to_s

          # refresh linode state with provider and output ip address
          linode = Provider.linode(@machine, :refresh => true)
          public_network = linode.networks.find { |network| network['ispublic'] == '1' }
          # private_network = linode.networks.find { |network| network['ispublic'] == '0' }
          env[:ui].info I18n.t('vagrant_linode.info.linode_ip', {
            :ip => public_network['ip_address']
          })
          if private_network
            env[:ui].info I18n.t('vagrant_linode.info.linode_private_ip', {
              :ip => private_network['ip_address']
            })
          end

          # wait for ssh to be ready
          switch_user = @machine.provider_config.setup?
          user = @machine.config.ssh.username
          @machine.config.ssh.username = 'root' if switch_user

          retryable(:tries => 120, :sleep => 10) do
            next if env[:interrupted]
            raise 'not ready' if !@machine.communicate.ready?
          end

          @machine.config.ssh.username = user

          @app.call(env)
        end

        # Both the recover and terminate are stolen almost verbatim from
        # the Vagrant AWS provider up action
        def recover(env)
          return if env['vagrant.error'].is_a?(Vagrant::Errors::VagrantError)
puts YAML::dump env
          if @machine.state.id != :not_created
            terminate(env)
          end
        end

        def terminate(env)
          destroy_env = env.dup
          destroy_env.delete(:interrupted)
          destroy_env[:config_validate] = false
          destroy_env[:force_confirm_destroy] = true
          env[:action_runner].run(Actions.destroy, destroy_env)
        end
      end
    end
  end
end
