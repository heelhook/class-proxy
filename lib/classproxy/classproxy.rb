# This module provides a primitive for data models to establish a main
# data source (as a cache or for any data conversion/merging operation)
module ClassProxy
  extend ActiveSupport::Concern

  class NotFound < StandardError; end

  module ClassMethods
    # This method establishes how a the cache should be hit, it receives a
    # hash with the data used for the query. If this method doesn't find
    # anything the fallbacks will be triggered
    #
    # @example Use with Active Record
    #   model.primary_fetch { |query| where(query).first }
    def primary_fetch(&block); @primary_fetch = block; end

    # Method used as fallback when the cache misses a hit fetch
    #
    # @example Using Github API for queries
    #   class GithubUser
    #     include ClassProxy
    #
    #     fallback_fetch { |args| Octokit.user(args[:login]) }
    #   end
    def fallback_fetch(&block); @fallback_fetch = block; end

    # Method that post-processes fallbacks, useful to reconvert data
    # from a fallback format into the model format
    #
    # @example Store Github API name in a different attribute
    #   class GithubUser
    #     include ClassProxy
    #
    #     fallback_fetch { |args| Octokit.user(args[:login]) }
    #     after_fallback_fetch do |obj|
    #       # obj is what `fallback_fetch` returns
    #       self.name  = obj.name
    #       self.login = obj.login
    #     end
    #
    #     attr_accessor :name, :login
    #   end
    def after_fallback_fetch(&block); @after_fallback_method = block; end

    # Establish attributes to proxy along with an alternative proc of how
    # the attribute should be loaded
    #
    # @example Load method using uppercase
    #   class GithubUser
    #     include ClassProxy
    #
    #     fallback_fetch { |args| Octokit.user(args[:login]) }
    #     after_fallback_fetch { |obj| self.name = obj.name; self.login = obj.login }
    #
    #     attr_accessor :name, :followers :login
    #
    #     proxy_methods :name, :followers, uppercase_login: lambda { login.upcase }
    #   end
    #
    #   user = GithubUser.find(login: 'heelhook')
    #   user.login           # -> 'heelhook'
    #   user.uppercase_login # -> 'HEELHOOK'
    def proxy_methods(*methods)
      @_methods ||= {}

      methods.each do |method|
        if method.is_a? Symbol
          # If given a symbol, store as a method to overwrite and use the default loader
          proxy_method method
        elsif method.is_a? Hash
          # If its a hash it will include methods to overwrite along with custom loaders
          method.each { |method_name, proc| proxy_method method_name, proc }
        end
      end
    end

    # Method to find a record using a hash as the criteria
    #
    # @example
    #   class GithubUser
    #     include MongoMapper::Document
    #     include ClassProxy
    #
    #     primary_fetch  { |args| where(args).first or (raise NotFound) }
    #     fallback_fetch { |args| Octokit.user(args[:login]) }
    #   end
    #
    #   GithubUser.fetch(login: 'heelhook') # -> Uses primary_fetch
    #                                       # -> and, if NotFound, fallback_fetch
    #
    # @param [ Hash ] args The criteria to use
    # @options options [ true, false] :skip_fallback Don't use fallback methods
    def fetch(args, options={})
      @primary_fetch.is_a?(Proc) ? @primary_fetch[args] : (raise NotFound)
    rescue NotFound
      return nil if options[:skip_fallback]

      run_fallback(args)
    end

    private

    def run_fallback(args, _self=nil)
      fallback_obj = @fallback_fetch[args]

      # Use the after_fallback_method
      obj = _self || self.new
      obj.instance_exec fallback_obj, &@after_fallback_method if @after_fallback_method.is_a? Proc

      # Go through the keys of the return object and try to use setters
      if fallback_obj and obj and fallback_obj.respond_to? :keys and fallback_obj.keys.respond_to? :each
        fallback_obj.keys.each do |key|
          next unless obj.respond_to? "#{key}="

          # check if its set to something else
          get_method = obj.respond_to?("no_proxy_#{key}") ? "no_proxy_#{key}" : key
          if obj.respond_to? get_method and obj.send(get_method) == nil
            obj.send("#{key}=", fallback_obj.send(key))
          end
        end
      end

      return obj
    end

    def proxy_method(method_name, proc=nil)
      self.class_eval do
        alias_method "no_proxy_#{method_name}".to_sym, method_name

        define_method(method_name) do |*args|
          # Use the no_proxy one first
          v = self.send("no_proxy_#{method_name}".to_sym, *args)

          # TODO -- Cache if this also returned nil so the fallback is not used
          #         constantly on actual nil values

          # Since AR calls the getter method when using the setter method
          # to establish the dirty attribute, since the getter is being replaced
          # here and the setter is being used when appropriate, the @mutex_in_call_for
          # prevents endless recursion.
          @mutex_in_call_for ||= []
          if v == nil and not @mutex_in_call_for.include? method_name
            @mutex_in_call_for << method_name
            method = "_run_fallback_#{method_name}".to_sym
            if self.respond_to?(method)
              v = if self.method(method).arity == 1
                # Callback method is expecting to receive the fallback object
                fallback_fetch_method = self.class.instance_variable_get(:@fallback_fetch)
                fallback_obj = fallback_fetch_method[self]
                self.send(method, fallback_obj)
              else
                # Callback method doesn't need the fallback object
                self.send(method)
              end
            else
              # This method has no callback, so just run the fallback
              args_class = ArgsClass.new(self)
              self.class.send :run_fallback, args_class, self

              # The value might have changed, so check here
              v = self.send("no_proxy_#{method_name}".to_sym)
            end

            # Set the defaults when this class responds to the same method
            self.send("#{method_name}=".to_sym, v) if v and self.respond_to?("#{method_name}=")
            @mutex_in_call_for.delete method_name
          end

          return v
        end
      end

      # Now define the fallback that is going to be used
      self.send(:define_method, "_run_fallback_#{method_name}", &proc) if proc.is_a? Proc
    end
  end

  def self.included(receiver)
    receiver.extend ClassMethods
  end

  # This class makes methods accessible as a hash key, useful to pass
  # as a fallback_fetch argument
  class ArgsClass < BasicObject
    def initialize(object)
      @target = object
    end

    def [](key)
      @target.respond_to?(key) ? @target.send(key) : @target[key]
    end
  end
end