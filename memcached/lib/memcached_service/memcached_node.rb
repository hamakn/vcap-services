# Copyright (c) 2012 NTT Communications
#       UEMURA Yuichi <y.uemura@ntt.com>
#       OZAWA Tsuyoshi <ozawa.tsuyoshi@gmail.com>
# Copyright (c) 2009-2011 VMware, Inc.
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#
# This code is based on Redis as a Service.

require "erb"
require "fileutils"
require "logger"
require "pp"

require "uuidtools"
require 'dalli'
require "thread"

$LOAD_PATH.unshift File.join(File.dirname(__FILE__), '..', '..', '..', 'base', 'lib')
require 'base/node'
require "datamapper_l"

module VCAP
  module Services
    module Memcached
      class Node < VCAP::Services::Base::Node
      end
    end
  end
end

require "memcached_service/common"
require "memcached_service/memcached_error"

class VCAP::Services::Memcached::Node

  include VCAP::Services::Memcached::Common
  include VCAP::Services::Memcached

  class SASLAdmin
    class SASLOperationError < StandardError
      SASL_OPS_CREATE_USER_FAILED = 'Failed to create user. Specified user has already exists.'
      SASL_OPS_UNKNOWN_ERROR      = 'Failed to create user. Unknown error.'
    end

    def initialize(logger)
      @logger = logger
    end

    def user_list
      # FIXME: a bit ugly, but works
      list_str = `sasldblistusers2`.split
      list_str.delete('userPassword')
      users = list_str.map do |e|
        separator = e.index('@') - 1
        e.slice(0..separator)
      end

      return users
    end

    def create_user(user, password)
      # FIME: error handling about priviredge.
      users = user_list()

      if users.include?(user)
        raise SASLOperationError::SASL_OPS_CREATE_USER_FAILED
      end

      ret = `echo '#{password}' | saslpasswd2 -a memcached -c #{user}  -p`

      if ret == ''
        return true
      end

      raise SASLOperationError::SASL_OPS_UNKNOWN_ERROR
    end

    def delete_user(user)
      # FIME: error handling about priviredge.
      ret = `saslpasswd2 -d #{user}`
    end
  end

  class ProvisionedService
    include DataMapper::Resource
    property :name,       String,   :key => true
    property :port,       Integer,  :unique => true
    property :user,       String,   :required => true
    property :password,   String,   :required => true
    property :plan,       Enum[:free], :required => true
    property :pid,        Integer
    property :memory,     Integer

    def listening?
      begin
        TCPSocket.open('localhost', port).close
        return true
      rescue => e
        return false
      end
    end

    def running?
      VCAP.process_running? pid
    end
  end

  def initialize(options)
    super(options)

    @logger.warn("local_ip: #{@local_ip}")
    @sasl_admin = SASLAdmin.new(@logger)
    @base_dir = options[:base_dir]
    FileUtils.mkdir_p(@base_dir)
    @memcached_server_path = options[:memcached_server_path]
    @available_memory = options[:available_memory]
    @available_memory_mutex = Mutex.new
    @max_memory = options[:max_memory]
    @free_ports = Set.new
    @free_ports_mutex = Mutex.new
    options[:port_range].each {|port| @free_ports << port}
    @local_db = options[:local_db]
    @disable_password = "disable-#{UUIDTools::UUID.random_create.to_s}"
    @memcached_log_dir = options[:memcached_log_dir]
    @config_command_name = '' # @options[:command_rename_prefix] + "-config"
    @shutdown_command_name = 'kill'  #@options[:command_rename_prefix] + "-shutdown"
    @max_clients = @options[:max_clients] || 500
    @memcached_timeout = @options[:memcached_timeout] || 2
  end

  def pre_send_announcement
    super
    start_db
    start_provisioned_instances
  end

  def shutdown
    super
    ProvisionedService.all.each do |instance|
      stop_memcached_server(instance)
    end
    true
  end

  def announcement
    @available_memory_mutex.synchronize do
      a = {
          :available_memory => @available_memory
      }
    end
  end

  def provision(plan, credentials = nil, db_file = nil)
    instance = ProvisionedService.new
    instance.plan = plan
    if credentials
      instance.name = credentials["name"]
      @free_ports_mutex.synchronize do
        if @free_ports.include?(credentials["port"])
          @free_ports.delete(credentials["port"])
          instance.port = credentials["port"]
        else
          port = @free_ports.first
          @free_ports.delete(port)
          instance.port = port
        end
      end
      instance.user = credentials["user"]
      instance.password = credentials["password"]
    else
      @free_ports_mutex.synchronize do
        port = @free_ports.first
        @free_ports.delete(port)
        instance.port = port
      end
      instance.name = UUIDTools::UUID.random_create.to_s
      instance.user = UUIDTools::UUID.random_create.to_s
      instance.password = UUIDTools::UUID.random_create.to_s
    end

    begin
      instance.memory = memory_for_instance(instance)
      @available_memory_mutex.synchronize do
        @available_memory -= instance.memory
      end
    rescue => e
      raise e
    end
    begin
      instance.pid = start_instance(instance, db_file)
      save_instance(instance)
    rescue => e1
      begin
        cleanup_instance(instance)
      rescue => e2
        # Ignore the rollback exception
      end
      raise e1
    end

    # Sleep 1 second to wait for memcached instance start
    sleep 1
    gen_credentials(instance)
  end

  def unprovision(instance_id, credentials_list = [])
    instance = get_instance(instance_id)
    @logger.warn("instance: #{instance.to_s}")
    cleanup_instance(instance)
    {}
  end

  def bind(instance_id, binding_options = :all, credentials = nil)
    # FIXME: Memcached has no user level security, just return provisioned credentials.
    instance = nil
    if credentials
      instance = get_instance(credentials["name"])
    else
      instance = get_instance(instance_id)
    end
    gen_credentials(instance)
  end

  def unbind(credentials)
    # FIXME: Memcached has no user level security, so has no operation for unbinding.
    {}
  end

  def restore(instance_id, backup_dir)
    # No restore command for memcached
    raise MemcachedError.new(MemcachedError::MEMCACHED_RESTORE_FILE_NOT_FOUND, dump_file)
    {}
  end

  def disable_instance(service_credentials, binding_credentials_list = [])
    instance = get_instance(service_credentials["name"])
    stop_instance(instance)
    true
  end

  # This function may run in old node or new node, it does these things:
  # 1. Try to use password in credentials to connect to memcached instance
  # 2. If connection failed, then it's the old node,
  #    since the password old node is changed to deny then access,
  #    if successed, then it's the new node.
  # 3. For old node, it should restore the password,
  #    for new node, nothing need to do, all are done in import_instance.
  def enable_instance(service_credentials, binding_credentials_map = {})
    instance = get_instance(service_credentials["name"])
    if check_password(instance.port, instance.password)
      # The new node
      service_credentials = gen_credentials(instance)
      binding_credentials_map.each do |key, value|
        binding_credentials_map[key]["credentials"] = gen_credentials(instance)
      end
    else
      # The old node
      set_config(service_credentials["port"], @disable_password, "requirepass", service_credentials["password"])
    end
    [service_credentials, binding_credentials_map]
  rescue => e
    @logger.warn(e)
    nil
  end

  def dump_instance(service_credentials, binding_credentials_list = [], dump_dir)
    # Memcached doesn't have support for dumping
    true
  end

  def import_instance(service_credentials, binding_credentials_list = [], dump_dir, plan)
    # Memcached doesn't have support for importing
    nil
  end

  def varz_details
    varz = {}
    varz[:provisioned_instances] = []
    varz[:provisioned_instances_num] = 0
    @available_memory_mutex.synchronize do
      varz[:max_instances_num] = @options[:available_memory] / @max_memory
    end
    ProvisionedService.all.each do |instance|
      varz[:provisioned_instances] << get_varz(instance)
      varz[:provisioned_instances_num] += 1
    end
    varz
  rescue => e
    @logger.warn("Error while getting varz details: #{e}")
    {}
  end

  def healthz_details
    healthz = {}
    healthz[:self] = "ok"
    ProvisionedService.all.each do |instance|
      healthz[instance.name.to_sym] = get_healthz(instance)
    end
    healthz
  rescue => e
    @logger.warn("Error while getting healthz details: #{e}")
    {:self => "fail"}
  end

  def start_db
    DataMapper.setup(:default, @local_db)
    DataMapper::auto_upgrade!
  end

  def start_provisioned_instances
    ProvisionedService.all.each do |instance|
      @free_ports_mutex.synchronize do
        @free_ports.delete(instance.port)
      end
      if instance.listening?
        @logger.warn("Service #{instance.name} already running on port #{instance.port}")
        @available_memory_mutex.synchronize do
          @available_memory -= (instance.memory || @max_memory)
        end
        next
      end
      begin
        pid = start_instance(instance)
        instance.pid = pid
        save_instance(instance)
      rescue => e
        @logger.warn("Error starting instance #{instance.name}: #{e}")
        begin
          cleanup_instance(instance)
        rescue => e2
          # Ignore the rollback exception
        end
      end
    end
  end

  def save_instance(instance)
    raise MemcachedError.new(MemcachedError::MEMCACHED_SAVE_INSTANCE_FAILED, instance.inspect) unless instance.save
  end

  def destroy_instance(instance)
    raise MemcachedError.new(MemcachedError::MEMCACHED_DESTROY_INSTANCE_FAILED, instance.inspect) unless instance.destroy
  end

  def get_instance(name)
    instance = ProvisionedService.get(name)
    raise MemcachedError.new(MemcachedError::MEMCACHED_FIND_INSTANCE_FAILED, name) if instance.nil?
    instance
  end

  def build_option_string(opt)
    # ./memcached -m memory_size -p port_num -c connection -P pid_file -t -vvv -S
    str = ''
    str << " -m #{opt['memory']}"
    str << " -p #{opt['port']}"
    str << " -c #{opt['maxclients']}"
    str << " -vvv"
    str << " -S"

    return str
  end

  def start_instance(instance, db_file = nil)
    @logger.debug("Starting: #{instance.inspect} on port #{instance.port}")

    pid = fork
    if pid
      @logger.debug("Service #{instance.name} started with pid #{pid}")
      # In parent, detch the child.
      Process.detach(pid)
      pid
    else
      $0 = "Starting Memcached instance: #{instance.name}"
      opt = {}
      opt['memory'] = instance.memory
      opt['port'] = instance.port
      opt['password'] = instance.password
      opt['name'] = instance.name
      opt['maxclients'] = @max_clients

      option_string = build_option_string(opt)
      @logger.warn("#{@memcached_server_path} #{option_string}")

      close_fds

      # create user
      @sasl_admin.create_user(instance.user, instance.password)

      log_dir = instance_log_dir(instance.name)
      log_file = File.join(log_dir, "memcachded.log")

      config_command = @config_command_name
      shutdown_command = @shutdown_command_name
      maxclients = @max_clients

      FileUtils.mkdir_p(log_dir)

      exec("#{@memcached_server_path} #{option_string} > #{log_file}")
    end
  rescue => e
    p e
    @sasl_admin.delete_user(instance.user)
    raise MemcachedError.new(MemcachedError::MEMCACHED_START_INSTANCE_FAILED, instance.inspect)
  end

  def stop_instance(instance)
    stop_memcached_server(instance)
    EM.defer do
      FileUtils.rm_rf(instance_dir(instance.name))
      FileUtils.rm_rf(instance_log_dir(instance.name))
    end
  end

  def cleanup_instance(instance)
    err_msg = []
    begin
      stop_instance(instance) if instance.running?
    rescue => e
      err_msg << e.message
    end
    @available_memory_mutex.synchronize do
      @available_memory += instance.memory
    end
    @free_ports_mutex.synchronize do
      @free_ports.add(instance.port)
    end
    begin
      destroy_instance(instance)
    rescue => e
      err_msg << e.message
    end
    raise MemcachedError.new(MemcachedError::MEMCACHED_CLEANUP_INSTANCE_FAILED, err_msg.inspect) if err_msg.size > 0
  end

  def memory_for_instance(instance)
    case instance.plan
      when :free then 16
      else
        raise MemcachedError.new(MemcachedError::MEMCACHED_INVALID_PLAN, instance.plan)
    end
  end

  def stop_memcached_server(instance)
    Timeout::timeout(@memcached_timeout) do
      @sasl_admin.delete_user(instance.user)
      `kill #{instance.pid}`
    end
  rescue Timeout::Error => e
    @logger.warn(e)
  end

  def close_fds
    3.upto(get_max_open_fd) do |fd|
      begin
        IO.for_fd(fd, "r").close
      rescue
      end
    end
  end

  def get_max_open_fd
    max = 0

    dir = nil
    if File.directory?("/proc/self/fd/") # Linux
      dir = "/proc/self/fd/"
    elsif File.directory?("/dev/fd/") # Mac
      dir = "/dev/fd/"
    end

    if dir
      Dir.foreach(dir) do |entry|
        begin
          pid = Integer(entry)
          max = pid if pid > max
        rescue
        end
      end
    else
      max = 65535
    end

    max
  end

  def check_password(port, password)
    Timeout::timeout(@memcached_timeout) do
      #memcached = Dalli::Client.new({:port => port})
      #memcached.auth(password)
    end
    true
  rescue => e
    if e.message == "ERR invalid password"
      return false
    else
      raise MemcachedError.new(MemcachedError::MEMCACHED_CONNECT_INSTANCE_FAILED)
    end
  ensure
    begin
      memcached.close if memcached
    rescue => e
    end
  end

  def get_info(instance)
    user = instance.user
    password = instance.password
    hostname = 'localhost:' + instance.port.to_s
    info = nil
    Timeout::timeout(@memcached_timeout) do
      memcached = Dalli::Client.new(hostname, username: user, password: password)
      info = memcached.stats
    end
  rescue => e
    raise MemcachedError.new(MemcachedError::MEMCACHED_CONNECT_INSTANCE_FAILED)
  ensure
    begin
      memcached.close if memcached
      return info[info.keys.first]
    rescue => e
    end
  end

  def get_config(port, password, key)
    config = nil
    Timeout::timeout(@memcached_timeout) do
      #memcached = Dalli::Client.new({:port => port, :password => password})
      #config = memcached.config(@config_command_name, :get, key)[key]
      raise MemcachedError.new(MemcachedError::MEMCACHED_NOT_YET_IMPLEMTED)
    end
    config
  rescue => e
    raise MemcachedError.new(MemcachedError::MEMCACHED_CONNECT_INSTANCE_FAILED)
  ensure
    begin
      memcached.close if memcached
    rescue => e
    end
  end

  def set_config(port, password, key, value)
    Timeout::timeout(@memcached_timeout) do
      # FIXME: connect to dalli servier ans config support
      raise MemcachedError.new(MemcachedError::MEMCACHED_NOT_YET_IMPLEMTED)
    end
  rescue => e
    raise MemcachedError.new(MemcachedError::MEMCACHED_CONNECT_INSTANCE_FAILED)
  ensure
    begin
      memcached.close if memcached
    rescue => e
    end
  end

  def get_varz(instance)
    @logger.info("Connect to instance: localhost:#{instance.port} #{instance.name}")
    info = get_info(instance)
    varz = {}
    varz[:name] = instance.name
    varz[:port] = instance.port
    varz[:plan] = instance.plan
    varz[:usage] = {}
    varz[:usage][:max_memory] = instance.memory.to_f * 1024.0
    varz[:usage][:max_clients] = @max_clients

    varz[:usage][:bytes] = info['bytes']
    varz[:usage][:reserved_fds] = info['reserved_fds']
    varz[:usage][:accepting_conns] = info['accepting_conns']
    varz[:usage][:uptime] = info['uptime']
    varz[:usage][:limit_maxbytes] = info['limit_maxbytes']
    varz[:usage][:bytes_read] = info['bytes_read']
    @logger.info("varz: #{varz.inspect}")
    varz
  end

  def gen_credentials(instance)
    @logger.warn("local_ip: #{@local_ip}")
    credentials = {
      "hostname" => @local_ip,
      "host" => @local_ip,
      "port" => instance.port,
      "user" => instance.user,
      "password" => instance.password,
      "name" => instance.name
    }
  end

  def get_healthz(instance)
    Timeout::timeout(@memcached_timeout) do
      memcached = Dalli::Client.new({:port => instance.port, :user => instance.user, :password => instance.password})
      memcached.stats
    end
    "ok"
  rescue => e
    "fail"
  ensure
    begin
      memcached.close if memcached
    rescue => e
    end
  end

  def instance_dir(instance_id)
    File.join(@base_dir, instance_id)
  end

  def instance_log_dir(instance_id)
    File.join(@memcached_log_dir, instance_id)
  end

end
