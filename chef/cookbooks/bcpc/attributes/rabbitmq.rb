###############################################################################
# rabbitmq
###############################################################################

# source rabbitmq from 3rd party apt repository
default['bcpc']['rabbitmq']['source']['repo']['enabled'] = false
default['bcpc']['rabbitmq']['source']['repo']['url'] = 'http://dl.bintray.com/rabbitmq/debian'

if platform?('ubuntu') && node['platform_version'] == '18.04'
  # source rabbitmq from a different distribution
  default['bcpc']['rabbitmq']['source']['distribution']['enabled'] = true
  default['bcpc']['rabbitmq']['source']['distribution']['name'] = 'bionic-backports'
end

# if changing this setting, you will need to reset Mnesia
# on all RabbitMQ nodes in the cluster
default['bcpc']['rabbitmq']['durable_queues'] = true

# ulimits for RabbitMQ server
default['bcpc']['rabbitmq']['ulimit']['nofile'] = 4096

# Heartbeat timeout to detect dead RabbitMQ brokers
default['bcpc']['rabbitmq']['heartbeat'] = 60

# TTL for messages on the Nova (versioned) notifications queue that is consumed
# by Watcher
default['bcpc']['rabbitmq']['message_ttl']['watcher'] = 10 * 60 * 1000 # 10 minutes
