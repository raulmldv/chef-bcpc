###############################################################################
# magnum
###############################################################################

default['bcpc']['magnum']['enabled'] = true

# database
default['bcpc']['magnum']['db']['dbname'] = 'magnum'
default['bcpc']['magnum']['database']['max_overflow'] = 10
default['bcpc']['magnum']['database']['max_pool_size'] = 5

# workers parameters for magnum-api and heat-engine set to number of CPUs
# available by default. This provides an override.
default['bcpc']['magnum']['api_workers'] = 1
default['bcpc']['magnum']['conductor_workers'] = 1
