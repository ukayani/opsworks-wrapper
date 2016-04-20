require "opsworks_wrapper/version"

module OpsworksWrapper
  class Deployer
    require 'aws-sdk'
    require 'colorize'

    def initialize(app_id)
      @app_id = app_id
    end

    def current_sha
      @current_sha ||= `git rev-parse HEAD`.chomp
    end

    def opsworks_app
      @opsworks_app ||= get_opsworks_app
    end

    def opsworks_client
      @opsworks_client ||= Aws::OpsWorks::Client.new
    end

    def load_balancer_client
      @client ||= Aws::ElasticLoadBalancing::Client.new
    end

    def app_id
      @app_id
    end

    def layers
      @layers ||= get_opsworks_layers
    end

    def get_opsworks_layers
      data = opsworks_client.describe_layers(stack_id: opsworks_app[:stack_id])
      layers = {}
      data.layers.each do |layer|
        layers[layer.name] = layer
      end
      layers
    end

    def get_opsworks_app
      data = opsworks_client.describe_apps(app_ids: [app_id])
      unless data[:apps] && data[:apps].count == 1
        raise Error, "App #{app_id} not found.", error.backtrace
      end
      data[:apps].first
    end

    def get_instances(layer_name = nil)
      if layer_name == nil
        data = opsworks_client.describe_instances(stack_id: opsworks_app[:stack_id])
      else
        layer_id = layers[layer_name].layer_id
        data = opsworks_client.describe_instances(layer_id: layer_id)
      end

      data.instances
    end

    def get_elb(layer_name)
      layer_id = layers[layer_name].layer_id
      elbs = opsworks_client.describe_elastic_load_balancers(layer_ids:[layer_id])
      if elbs.elastic_load_balancers.size > 0
        name = elbs.elastic_load_balancers.first.elastic_load_balancer_name
        ELB.new(name)
      else
        nil
      end
    end

    # update cookbooks on all layers
    def update_cookbooks(timeout = 150)
      puts 'Updating cookbooks'.light_white.bold
      create_deployment({name: 'update_custom_cookbooks'}, nil, timeout)
    end

    # deploy to specified layer or all layers (default)
    def deploy(layer_name = nil, timeout = 600)
      if layer_name
        puts "Deploying on #{layer_name} layer".light_white.bold
        instance_ids = get_instances(layer_name).map(&:instance_id)
      else
        puts "Deploying on all layers".light_white.bold
        instance_ids = nil
      end

      create_deployment({name: 'deploy'}, instance_ids, timeout)
    end

    def roll_instance(instance, elb, timeout = 600)
      if !elb.nil?
        elb.remove_instance(instance)
      end

      create_deployment({name: 'deploy'}, [instance.instance_id], timeout)

      if !elb.nil?
        elb.add_instance(instance)
      end

    end

    # deploy to all layers except specified layer
    def deploy_exclude(layer_name, timeout = 600)
      puts "Deploying to all layers except #{layer_name}".light_white.bold
      create_deployment_exclude({name: 'deploy'}, layer_name, timeout)
    end

    def create_deployment_exclude(command, layer_to_exclude, timeout)
      all_instance_ids = get_instances.map(&:instance_id)
      excluded_instance_ids = get_instances(layer_to_exclude).map(&:instance_id)
      included_instance_ids = all_instance_ids - excluded_instance_ids

      create_deployment(command, included_instance_ids, timeout)
    end

    def create_deployment(command, instance_ids, timeout)
      deployment_config = {
          stack_id: opsworks_app[:stack_id],
          app_id: app_id,
          instance_ids: instance_ids,
          command: command,
          comment: "Git Sha: #{current_sha}"
      }

      deployment = opsworks_client.create_deployment(deployment_config)
      puts "Running Command: #{command[:name]} ".light_blue

      begin
        wait_until_deployed(deployment[:deployment_id], timeout)
        puts "Deployment successful".green
        true
      rescue Aws::Waiters::Errors::WaiterFailed => e
        puts  "Failed to deploy: #{e.message}".red
        false
      end
    end

    # Waits on the provided deployment for specified timeout (seconds)
    def wait_until_deployed(deployment_id, timeout)
      opsworks_client.wait_until(:deployment_successful, deployment_ids: [deployment_id]) do |w|
        w.before_attempt do |attempt|
          puts "Attempt #{attempt} to check deployment status".light_black
        end
        w.interval = 10
        w.max_attempts = timeout / w.interval
      end
    end
    private :wait_until_deployed
  end

  class ELB
    require 'aws-sdk'
    require 'colorize'

    def initialize(name)
      @name = name
    end

    def name
      @name
    end

    def client
      @client ||= Aws::ElasticLoadBalancing::Client.new
    end

    def attributes
      @attributes ||= client.describe_load_balancer_attributes(load_balancer_name: name)
    end

    def health_check
      elb = client.describe_load_balancers(load_balancer_names: [name]).load_balancer_descriptions.first
      @health_check ||= elb.health_check
    end

    def wait_for_connection_draining
      connection_draining = attributes.load_balancer_attributes.connection_draining
      if connection_draining.enabled
        timeout = connection_draining.timeout
        puts "Connection Draining Enabled - sleeping for #{timeout}".light_black
        sleep(timeout)
      else
        puts "Connection Draining Disabled - sleeping for 20 seconds".light_black
        sleep(20)
      end
    end

    def wait_for_instance_health_check(instance)
      health_threshold = health_check.healthy_threshold
      interval = health_check.interval

      # wait a little longer than the defined threshold to account for application launch time
      timeout = ((health_threshold + 2) * interval)

      begin
        client.wait_until(:instance_in_service, {load_balancer_name: name,
                                                 instances: [{instance_id: instance.ec2_instance_id}]}) do |w|
          w.before_attempt do |attempt|
            puts "Attempt #{attempt} to check health status for #{instance.hostname}".light_black
          end
          w.interval = 10
          w.max_attempts = timeout / w.interval
        end
        puts "Instance #{instance.hostname} is now InService".green
        true
      rescue Aws::Waiters::Errors::WaiterFailed => e
        puts "Instance #{instance.hostname} failed to move to InService, #{e.message}".red
        false
      end

    end

    def remove_instance(instance)
      deregister_response = client.deregister_instances_from_load_balancer(load_balancer_name: name,
                                                                           instances: [{instance_id: instance.ec2_instance_id}])
      remaining_instance_count = deregister_response.instances.size
      puts "Removed #{instance.hostname} from ELB #{name}. Remaining instances: #{remaining_instance_count}".light_blue
      wait_for_connection_draining
    end

    def add_instance(instance)
      register_response = client.register_instances_with_load_balancer(load_balancer_name: name,
                                                                       instances: [{instance_id: instance.ec2_instance_id}])
      remaining_instance_count = register_response.instances.size
      puts "Added #{instance.hostname} to ELB #{name}. Attached instances: #{remaining_instance_count}".light_blue
      wait_for_instance_health_check(instance)
    end

    def is_instance_healthy(instance)
      instance_health = client.describe_instance_health(load_balancer_name: name,
                                                        instances: [{instance_id: instance.ec2_instance_id}])
      state_info = instance_health.instance_states.first
      status_detail = ''
      if state_info.state != 'InService'
        status_detail = "#{state_info.reason_code} - #{state_info.description}."
      end
      puts "Instance state is #{state_info.state} #{status_detail}"
      state_info.state == 'InService'
    end

  end
end
