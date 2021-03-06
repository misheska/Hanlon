require 'socket'
require 'fcntl'
require 'yaml'
require 'utility'
require 'logging/logger'

# This class represents the ProjectHanlon configuration. It is stored persistently in
# './web/conf/hanlon_server.conf' and editing by the user

module ProjectHanlon
  module Config
    class Server
      include ProjectHanlon::Utility
      include ProjectHanlon::Logging
      extend  ProjectHanlon::Logging


      attr_reader   :hanlon_uri
      attr_reader   :websvc_root

      attr_accessor :hanlon_server

      attr_accessor :persist_mode
      attr_accessor :persist_host
      attr_accessor :persist_port
      attr_accessor :persist_username
      attr_accessor :persist_password
      attr_accessor :persist_timeout

      attr_accessor :base_path
      attr_accessor :api_version
      attr_accessor :admin_port
      attr_accessor :api_port
      attr_accessor :hanlon_log_level

      attr_accessor :mk_checkin_interval
      attr_accessor :mk_checkin_skew
      attr_accessor :mk_fact_excl_pattern

      # mk_log_level should be 'Logger::FATAL', 'Logger::ERROR', 'Logger::WARN',
      # 'Logger::INFO', or 'Logger::DEBUG' (default is 'Logger::ERROR')
      attr_accessor :mk_log_level
      attr_accessor :mk_tce_mirror
      attr_accessor :mk_tce_install_list_uri
      attr_accessor :mk_kmod_install_list_uri
      attr_accessor :mk_gem_mirror
      attr_accessor :mk_gemlist_uri

      attr_accessor :image_path

      attr_accessor :register_timeout
      attr_accessor :force_mk_uuid

      attr_accessor :daemon_min_cycle_time

      attr_accessor :node_expire_timeout

      attr_accessor :rz_mk_boot_debug_level
      attr_accessor :rz_mk_boot_kernel_args

      attr_accessor :sui_mount_path
      attr_accessor :sui_allow_access

      attr_reader   :noun

      # Return a fully configured instance of the configuration data.
      #
      # If a configuration file exists on disk, it is loaded and validated.
      #    else returns a nil file which needs to be validated
      #
      # @todo danielp 2013-03-13: this still doesn't address the race where a
      # *different* configuration is written to the default - in that case we
      # would totally just use the defaults rather than what was written.
      # If the original authors didn't care, though, I doubt that I should
      # care more deeply, rather than just delaying it until I replace the
      # model entirely.
      def self.instance
        unless @_instance

          if(File.exist?($config_file_path))
            config = YAML.load_file($config_file_path)
          else
            raise "Configuration file missing at #{$config_file_path}"
          end

          # OK, the first round of validation that this is a good config; this
          # also handles upgrading the schema stored in the YAML file, if needed.
          # ToDo::Sankar::Implement - improve configuration file validation
          #    return proper error messages on failed validation keys

          if config.is_a? ProjectHanlon::Config::Server
            config.defaults.each_pair {|key, value| config[key] ||= value }
          else
            raise "Invalid configuration file (#{$config_file_path})"
            config = nil
          end

          @_instance = config
        end

        return @_instance
      end

      # Reset the singleton to the default state, primarily used for testing.
      # @api private
      def self._reset_instance
        @_instance = nil
      end

      def initialize
        defaults.each_pair {|name, value| self[name] = value }
        @noun = "config"
      end
      private "initialize"

      # Obtain our defaults
      def defaults
        #base_path = SERVICE_CONFIG[:config][:swagger_ui][:base_path]
        #api_version = SERVICE_CONFIG[:config][:swagger_ui][:api_version]
        #default_websvc_root = "#{base_path}/#{api_version}"
        default_base_path = "/hanlon/api"
        default_image_path  = "#{$hanlon_root}/image"
        defaults = {
          'hanlon_server'            => get_an_ip,
          'persist_mode'             => :mongo,
          'persist_host'             => "127.0.0.1",
          'persist_port'             => 27017,
          'persist_username'         => '',
          'persist_password'         => '',
          'persist_timeout'          => 10,

          'base_path'                => default_base_path,
          'api_version'              => 'v1',
          'admin_port'               => 8025,
          'api_port'                 => 8026,

          'mk_checkin_interval'      => 60,
          'mk_checkin_skew'          => 5,
          'mk_fact_excl_pattern'     => [
            "(^facter.*$)", "(^id$)", "(^kernel.*$)", "(^memoryfree$)","(^memoryfree_mb$)",
            "(^operating.*$)", "(^osfamily$)", "(^path$)", "(^ps$)",
            "(^ruby.*$)", "(^selinux$)", "(^ssh.*$)", "(^swap.*$)",
            "(^timezone$)", "(^uniqueid$)", "(^uptime.*$)","(.*json_str$)"
          ].join("|"),
          'mk_log_level'             => "Logger::ERROR",
          'mk_gem_mirror'            => "http://localhost:2158/gem-mirror",
          'mk_gemlist_uri'           => "/gems/gem.list",
          'mk_tce_mirror'            => "http://localhost:2157/tinycorelinux",
          'mk_tce_install_list_uri'  => "/tce-install-list",
          'mk_kmod_install_list_uri' => "/kmod-install-list",

          'image_path'               => default_image_path,

          'register_timeout'         => 120,
          'force_mk_uuid'            => "",

          'daemon_min_cycle_time'    => 30,

          # this is the default value for the amount of time (in seconds) that
          # is allowed to pass before a node is removed from the system.  If the
          # node has not checked in for this long, it'll be removed
          'node_expire_timeout'      => 300,

          # DEPRECATED: use rz_mk_boot_kernel_args instead!
          # used to set the Microkernel boot debug level; valid values are
          # either the empty string (the default), "debug", or "quiet"
          'rz_mk_boot_debug_level'   => "Logger::ERROR",
          'hanlon_log_level'   => "Logger::ERROR",

          # used to pass arguments to the Microkernel's linux kernel;
          # e.g. "console=ttyS0" or "hanlon.ip=1.2.3.4"
          'rz_mk_boot_kernel_args'   => "",

          # config parameters for swagger_ui management (prefix::sui)
          'sui_mount_path'   => "/docs",
          'sui_allow_access'   => "true"
        }

        return defaults
      end

      # The fixed header injected at the top of any configuration file we write.
      ConfigHeader = <<EOT
#
# This file is the main configuration for ProjectHanlon
#
# -- this was system generated --
#
#
EOT

      # reader methods for derived parameters are defined here
      def hanlon_uri
        "http://#{hanlon_server}:#{api_port}"
      end

      def websvc_root
        "#{base_path}/#{api_version}"
      end

      # Save the current configuration instance as YAML to disk.
      #
      def save_as_yaml(conf_file_path)
        begin
          #fd = IO.sysopen(filename, Fcntl::O_WRONLY|Fcntl::O_CREAT|Fcntl::O_EXCL, 0600)
          #IO.open(fd, 'wb') {|fh| fh.puts ConfigHeader, YAML.dump(self) }

          if !File.file?(conf_file_path)

            FileUtils.mkdir_p(File.dirname(conf_file_path))
            File.open(conf_file_path, 'w') { |file| file.puts ConfigHeader, YAML.dump(self) }

          end
        rescue Exception => e
          # As per the original code, we treat any sort of failure as an
          # indication that we should just not give a damn about failures.
          #
          # If the file already existed, we will get here with Errno::E_EXISTS
          # as our exception.  If we want to handle that differently, that is
          # the path right there.
          logger.error "Could not save config to (#{conf_file_path})"
          logger.log_exception e
        end

        return self
      end

      # a few convenience methods that let us treat this class like a Hash map
      # (to a certain extent); first a "setter" method that lets users set
      # key/value pairs using a syntax like "config['param_name'] = param_value"
      def []=(key, val)
        # "@noun" is a "read-only" key for this class (there is no setter)
        return if key == "noun"
        self.send("#{key}=", val)
      end

      # next a "getter" method that lets a user get the value for a key using
      # a syntax like "config['param_name']"
      def [](key)
        self.send(key)
      end

      # next, a method that returns a list of the "key" fields from this class
      def keys
        self.to_hash.keys.map { |k| k.sub("@","") }
      end

      # and, finally, a method that gives users the ability to check and see
      # if a given parameter name is included in the list of "key" fields for
      # this class
      def include?(key)
        keys = self.to_hash.keys.map { |k| k.sub("@","") }
        keys.include?(key)
      end

      # returns the current "client configuration" parameters as a Hash map
      def get_client_config_hash
        config_hash = self.to_hash
        client_config_hash = {}
        config_hash.each_pair do
        |k,v|
          if k.start_with?("@mk_")
            client_config_hash[k.sub("@","")] = v
          end
        end
        client_config_hash
      end

      # override the standard "to_yaml" method so that these configurations
      # are saved in a sorted order (sorted by key)
      def to_yaml (opts = { })
        YAML::quick_emit(object_id, opts) do |out|
          out.map(taguri, to_yaml_style) do |map|
            sorted_keys = keys
            sorted_keys = begin
              sorted_keys.sort
            rescue
              sorted_keys.sort_by { |k| k.to_s } rescue sorted_keys
            end

            map.add("noun", self["noun"])
            sorted_keys.each do |k|
              next if k == "taguri" || k == "to_yaml_style"  || k == "noun"
              map.add(k, self[k])
            end

          end
        end
      end

      # uses the  UDPSocket class to determine the list of IP addresses that are
      # valid for this server (used in the "get_an_ip" method, below, to pick an IP
      # address to use when constructing the Hanlon configuration file)
      def local_ip
        # Base on answer from http://stackoverflow.com/questions/42566/getting-the-hostname-or-ip-in-ruby-on-rails
        orig, Socket.do_not_reverse_lookup = Socket.do_not_reverse_lookup, true  # turn off reverse DNS resolution temporarily

        UDPSocket.open do |s|
          s.connect '4.2.2.1', 1 # as this is UDP, no connection will actually be made
          s.addr.select {|ip| ip =~ /[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/}.uniq
        end
      ensure
        Socket.do_not_reverse_lookup = orig
      end

      # This method is used to guess at an appropriate value to use as an IP address
      # for the Hanlon server when constructing the Hanlon configuration file.  It returns
      # a single IP address from the set of IP addresses that are detected by the "local_ip"
      # method (above).  If no IP addresses are returned by the "local_ip" method, then
      # this method returns a default value of 127.0.0.1 (a localhost IP address) instead.
      def get_an_ip
        str_address = local_ip.first
        # if no address found, return a localhost IP address as a default value
        return '127.0.0.1' unless str_address
        # if we're using a version of Ruby other than v1.8.x, force encoding to be UTF-8
        # (to avoid an issue with how these values are saved in the configuration
        # file as YAML that occurs after Ruby 1.8.x)
        return str_address.force_encoding("UTF-8") unless /^1\.8\.\d+/.match(RUBY_VERSION)
        # if we're using Ruby v1.8.x, just return the string
        str_address
      end

    end
  end
end
