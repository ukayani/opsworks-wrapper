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

    # Returns a dictionary for all OpsWorks layers keyed by layer name
    # @return [Dictionary]
    def get_opsworks_layers
      data = opsworks_client.describe_layers(stack_id: opsworks_app[:stack_id])
      layers = {}
      data.layers.each do |layer|
        layers[layer.name] = layer
      end
      layers
    end

    # Returns OpsWorks app details
    # @return [Object]
    def get_opsworks_app
      data = opsworks_client.describe_apps(app_ids: [app_id])
      if !(data[:apps] && data[:apps].count == 1)
        raise Error, "App #{app_id} not found.", error.backtrace
      end
      data[:apps].first
    end


    # Returns a list of OpsWorks instances for a specific layer or all layers if @layer_name is not provided
    # @param [String] layer_name
    # @return [List[Object]] - List of OpsWorks instances
    def get_instances(layer_name = nil)
      if layer_name == nil
        data = opsworks_client.describe_instances(stack_id: opsworks_app[:stack_id])
      else
        layer_id = layers[layer_name].layer_id
        data = opsworks_client.describe_instances(layer_id: layer_id)
      end

      data.instances
    end

    # Returns ELB instance for layer if one is attached
    # @param [String] layer_name
    # @return [Object?] - ELB instance
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

    # Run update cookbooks on all layers
    # @param [Number] timeout
    # @return [Boolean]
    def update_cookbooks(timeout = 150)
      puts 'Updating cookbooks'.light_white.bold
      create_deployment({name: 'update_custom_cookbooks'}, nil, timeout)
    end

    # Run deploy command on specified layer or all layers if @layer_name is not specified (non rolling)
    # @param [String] layer_name
    # @param [Number] timeout
    # @return [Boolean]
    def deploy(layer_name = nil, timeout = 600)
      if layer_name
        puts "Deploying on #{layer_name} layer".light_white.bold
        instances = get_instances(layer_name)
      else
        puts "Deploying on all layers".light_white.bold
        instances = nil
      end

      create_deployment({name: 'deploy'}, instances, timeout)
    end

    # Performs a rolling deploy on each instance in the layer
    # If an elb is attached to the layer, de-registration and registration will be performed for the instance
    # @param [String] layer_name
    # @param [Number] timeout
    # @return [Boolean]
    def deploy_layer_rolling(layer_name, timeout = 600)
      instances = get_instances(layer_name)
      elb = get_elb(layer_name)
      success = true
      instances.each do |instance|
        success = deploy_instance_rolling(instance, elb, timeout)
        break if !success
      end
      success
    end

    # Performs rolling deployment on an instance
    # Will detach instance if elb is provided and re-attach after deployment succeeds
    # @param [Object] instance - opsworks instance
    # @param [Object] elb - elb instance
    # @param [Number] timeout
    # @return [Boolean]
    def deploy_instance_rolling(instance, elb, timeout = 600)
      if !elb.nil?
        elb.remove_instance(instance)
      end

      success = create_deployment({name: 'deploy'}, [instance], timeout)

      # only add instance back to elb if deployment succeeded
      if !elb.nil? && success
        success = elb.add_instance(instance)
      end

      success
    end

    # Deploy to all layers except specified layer (non-rolling)
    # @param [String] layer_name
    # @param [Number] timeout
    # @return [Boolean]
    def deploy_exclude(layer_name, timeout = 600)
      puts "Deploying to all layers except #{layer_name}".light_white.bold
      create_deployment_exclude({name: 'deploy'}, layer_name, timeout)
    end

    # Creates an OpsWorks deployment with specified command on all layers excluding layer_to_exclude
    # @param [Object] command - Opsworks deployment command
    # @param [String] layer_to_exclude
    # @param [Number] timeout
    # @return [Boolean]
    def create_deployment_exclude(command, layer_to_exclude, timeout)
      all_instances = get_instances
      excluded_instances = get_instances(layer_to_exclude)
      included_instances = all_instances - excluded_instances

      create_deployment(command, included_instances, timeout)
    end

    # Creates an OpsWorks deployment with specified command
    # If @instances is not nil, the deployment will only be performed on specified instances
    # @param [Object] command
    # @param [Array[Object]] instances
    # @param [Number] timeout
    # @return [Boolean]
    def create_deployment(command, instances, timeout)
      instance_ids = nil
      instance_description = "all instances"

      if !instances.nil?
        instance_ids = instances.map(&:instance_id)
        instance_description = instances.map(&:hostname).join(',')
      end

      deployment_config = {
          stack_id: opsworks_app[:stack_id],
          app_id: app_id,
          instance_ids: instance_ids,
          command: command,
          comment: "Git Sha: #{current_sha}"
      }

      deployment = opsworks_client.create_deployment(deployment_config)
      print "Running command ".light_blue
      print "#{command[:name]}".light_blue.bold
      puts " on #{instance_description}".light_blue

      begin
        _wait_until_deployed(deployment[:deployment_id], timeout)
        puts "Deployment successful".green
        true
      rescue Aws::Waiters::Errors::WaiterFailed => e
        puts  "Failed to deploy: #{e.message}".red
        false
      end
    end

    # Waits on the provided deployment for specified timeout (seconds)
    def _wait_until_deployed(deployment_id, timeout)
      opsworks_client.wait_until(:deployment_successful, deployment_ids: [deployment_id]) do |w|
        w.before_attempt do |attempt|
          puts "Attempt #{attempt} to check deployment status".light_black
        end
        w.interval = 10
        w.max_attempts = timeout / w.interval
      end
    end

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

    # Determines if elb has connection draining enabled and waits for the timeout period or (20s) default
    def _wait_for_connection_draining
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

    # Waits on instance to be in service according to the ELB
    # @param [Object] instance
    # @return [Boolean]
    def _wait_for_instance_health_check(instance)
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

    # Removes instance from ELB and waits for connection draining
    # @param [Object] instance - object with ec2_instance_id and hostname
    def remove_instance(instance)
      deregister_response = client.deregister_instances_from_load_balancer(load_balancer_name: name,
                                                                           instances: [{instance_id: instance.ec2_instance_id}])
      remaining_instance_count = deregister_response.instances.size
      puts "Removed #{instance.hostname} from ELB #{name}. Remaining instances: #{remaining_instance_count}".light_blue
      _wait_for_connection_draining
    end

    # Adds instance to ELB and waits for instance health check to pass
    # @param [Object] instance - object with ec2_instance_id and hostname
    # @return [Boolean]
    def add_instance(instance)
      register_response = client.register_instances_with_load_balancer(load_balancer_name: name,
                                                                       instances: [{instance_id: instance.ec2_instance_id}])
      remaining_instance_count = register_response.instances.size
      puts "Added #{instance.hostname} to ELB #{name}. Attached instances: #{remaining_instance_count}".light_blue
      _wait_for_instance_health_check(instance)
    end

    # Checks whether an instance attached to ELB is healthy
    # @param [Object] instance - object with ec2_instance_id and hostname
    # @return [Boolean]
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
