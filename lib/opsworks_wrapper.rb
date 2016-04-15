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

    def client
      @client ||= Aws::OpsWorks::Client.new
    end

    def app_id
      @app_id
    end

    def layers
      @layers ||= get_opsworks_layers
    end

    def get_opsworks_layers
      data = client.describe_layers(stack_id: opsworks_app[:stack_id])
      layers = {}
      data.layers.each do |layer|
        layers[layer.name] = layer
      end
      layers
    end

    def get_opsworks_app
      data = client.describe_apps(app_ids: [app_id])
      unless data[:apps] && data[:apps].count == 1
        raise Error, "App #{app_id} not found.", error.backtrace
      end
      data[:apps].first
    end

    def get_instances(layer_name = nil)
      if layer_name == nil
        data = client.describe_instances(stack_id: opsworks_app[:stack_id])
      else
        layer_id = layers[layer_name].layer_id
        data = client.describe_instances(layer_id: layer_id)
      end

      data.instances
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

      deployment = client.create_deployment(deployment_config)
      puts "Deployment created: #{deployment[:deployment_id]}".blue
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
      client.wait_until(:deployment_successful, deployment_ids: [deployment_id]) do |w|
        w.before_attempt do |attempt|
          puts "Attempt #{attempt} to check deployment status".light_black
        end
        w.interval = 10
        w.max_attempts = timeout / w.interval
      end
    end
    private :wait_until_deployed

  end
end
