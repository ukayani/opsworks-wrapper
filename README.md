# OpsworksWrapper

A simple wrapper for aws-sdk to make handling opsworks operations easier.

## Supported Operations

### Deployment
- Rolling/Non-Rolling deployment by layer
- Update custom cookbooks
- Non-Rolling Deployment Creation for all layers except a specified layer (exclusion by layer name)
- Retrieve all instances for a given layer name

### ELB
- Detach instance from ELB (wait for draining)
- Attach instance to ELB (wait for health check)

## Installation

Add this line to your application's Gemfile:

```ruby
gem 'opsworks_wrapper'
```

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install opsworks_wrapper

## Usage

Example OpsWorks Configuration

A simple OpsWorks stack with 2 layers, one is attached to an ELB

Layer 1:
 - name: Frontend
 - ELB attached: yes

Layer 2:
 - name: Backend
 - ELB attached: no

### Rolling Deployment

```ruby
require 'aws-sdk'
require 'opsworks_wrapper'

ACCESS_KEY = "yourAccessKey"
SECRET_KEY = "yourSecretKey"
OPSWORKS_APP_ID = "yourAppID"

# update AWS credentials
Aws.config.update({
                      region: 'us-east-1',
                      credentials: Aws::Credentials.new(ACCESS_KEY, SECRET_KEY)
                  })
                  
opsworks = OpsworksWrapper::Deployer.new(OPSWORKS_APP_ID)

# Do rolling deploy to backend layer
opsworks.deploy_layer_rolling('Backend')


# Do rolling deploy to frontend layer
# Note: Since frontend has an ELB, instances will be detached before deployment
# and re-attached. After re-attaching, wait for ELB health-check to pass
opsworks.deploy_layer_rolling('Frontend')
```

### Update Custom Cookbooks

```ruby
require 'aws-sdk'
require 'opsworks_wrapper'

ACCESS_KEY = "yourAccessKey"
SECRET_KEY = "yourSecretKey"
OPSWORKS_APP_ID = "yourAppID"

# update AWS credentials
Aws.config.update({
                      region: 'us-east-1',
                      credentials: Aws::Credentials.new(ACCESS_KEY, SECRET_KEY)
                  })
                  
opsworks = OpsworksWrapper::Deployer.new(OPSWORKS_APP_ID)

# Run command update-custom-cookbooks on all layers
# Note: this will not run deploy command
opsworks.update_cookbooks
```

## Contributions

Bug reports and pull requests are welcome on GitHub at https://github.com/ukayani/opsworks-wrapper. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [Contributor Covenant](http://contributor-covenant.org) code of conduct.


## License

The gem is available as open source under the terms of the [MIT License](http://opensource.org/licenses/MIT).

