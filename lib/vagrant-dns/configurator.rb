require 'fileutils'
require 'yaml'

module VagrantDNS
  class Configurator
    attr_accessor :vm, :tmp_path

    def initialize(vm, tmp_path)
      @vm = vm
      @tmp_path = tmp_path
    end

    def run!
      regenerate_resolvers!
      ensure_deamon_env!
      register_patterns!
    end

    private
      def regenerate_resolvers!
        FileUtils.mkdir_p(resolver_folder)

        port = VagrantDNS::Config.listen.first.last
        tlds = dns_options(vm)[:tlds]

        tlds.each do |tld|
          File.open(File.join(resolver_folder, tld), "w") do |f|
            f << resolver_file(port)
          end
        end
      end

      def register_patterns!
        opts     = dns_options(vm)

        patterns = opts[:patterns] || default_patterns(opts)
        if patterns.empty?
         vm.ui.warn '[vagrant-dns] TLD but no host_name given. No patterns will be configured.'
         return
        end

        ip = vm_ip(opts)
        unless ip
          vm.ui.detail '[vagrant-dns] No patterns will be configured.'
          return
        end

        registry = YAML.load(File.read(config_file)) if File.exists?(config_file)
        registry ||= {}

        patterns.each do |p|
          p = p.source if p.respond_to? :source # Regexp#to_s is unusable
          registry[p] = ip
        end

        File.open(config_file, "w") { |f| f << YAML.dump(registry) }
      end

      def dns_options(vm)
        return @dns_options if @dns_options

        @dns_options = vm.config.dns.to_hash
        @dns_options[:host_name] = vm.config.vm.hostname
        @dns_options[:networks] = vm.config.vm.networks
        @dns_options
      end

      def default_patterns(opts)
        if opts[:host_name]
          opts[:tlds].map { |tld| /^.*#{opts[:host_name]}.#{tld}$/ }
        else
          []
        end
      end

      def vm_ip(opts)
        user_ip = opts[:ip]

        ip =
          case user_ip
          when Proc
            if vm.communicate.ready?
              user_ip.call(vm, opts.dup.freeze)
            else
              vm.ui.info '[vagrant-dns] Postponing running user provided IP script until box has started.'
              return
            end
          when Symbol
            _ip = static_vm_ip(user_ip, opts)

            unless _ip
              vm.ui.warn "[vagrant-dns] Could not find any static network IP in network type `#{user_ip}'."
              return
            end

            _ip
          else
            _ip = static_vm_ip(:private_network, opts)
            _ip ||= static_vm_ip(:public_network, opts)

            unless _ip
              vm.ui.warn '[vagrant-dns] Could not find any static network IP.'
              return
            end

            _ip
          end

        if !ip || ip.empty?
          vm.ui.warn '[vagrant-dns] Failed to identify IP.'
          return
        end

        ip
      end

      # tries to find an IP in the configured +type+ networks
      def static_vm_ip(type, opts)
        network = opts[:networks].find do |nw|
          nw.first == type && nw.last[:ip]
        end

        network.last[:ip] if network
      end

      def resolver_file(port)
        contents = <<-FILE
# this file is generated by vagrant-dns
nameserver 127.0.0.1
port #{port}
FILE
      end

      def resolver_folder
        File.join(tmp_path, "resolver")
      end

      def ensure_deamon_env!
        FileUtils.mkdir_p(File.join(tmp_path, "daemon"))
      end

      def config_file
        File.join(tmp_path, "config")
      end
  end
end
