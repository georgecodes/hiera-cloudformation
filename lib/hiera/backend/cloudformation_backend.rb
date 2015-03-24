# Copyright 2013-2014 FanDuel Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'rubygems'
require 'aws'
require 'timedcache'
require 'redis'
require 'json'

class Hiera
  module Backend
    # Cache class that hides Redis vs. TimedCache implementation
    class Cache
      def initialize(type = nil)
        @type = type

        if Config.include?(:cloudformation) && !Config[:cloudformation].nil?
          if Config[:cloudformation].include?(:redis_hostname)
            @redis_hostname = Config[:cloudformation][:redis_hostname]
          end
        end

        if @redis_hostname
          @redis = redis.StrictRedis(@redis_hostname, 6379, 0)
        else
          @timedcache = TimedCache.new
        end
      end

      def get(key)
        if @redis
          @redis.get format_key(key)
        else
          @timedcache.get format_key(key)
        end
      end

      def put(key, value, timeout = 60)
        if @redis
          @redis.set(format_key(key), value)
        else
          @timedcache.put(format_key(key), value, timeout)
        end
      end

      # If key is Enumerable convert to a json string
      def format_key(key)
        if key.is_a? Enumberable
          key.to_json
        else
          key
        end
      end
    end

    class Cloudformation_backend
      TIMEOUT = 60  # 1 minute timeout for AWS API response caching

      def initialize
        if Config.include?(:cloudformation) && !Config[:cloudformation].nil?
          if Config[:cloudformation].fetch(:parse_metadata, false)
            Hiera.debug('Will convert CloudFormation stringified metadata back to numbers or booleans.')
            @parse_metadata = true
          else
            @parse_metadata = false
          end

          aws_config = {}
          if Config[:cloudformation].include?(:access_key_id) && Config[:cloudformation].include?(:secret_access_key)
            Hiera.debug("Found AWS access key #{Config[:cloudformation][:access_key_id]} from configuration")
            aws_config[:access_key_id] = Config[:cloudformation][:access_key_id]
            aws_config[:secret_access_key] = Config[:cloudformation][:secret_access_key]
          end
          if Config[:cloudformation].include?(:region)
            Hiera.debug("Found AWS region #{Config[:cloudformation][:region]} from configuration")
            aws_config[:region] = Config[:cloudformation][:region]
          end
          if aws_config.length != 0
            @cf = AWS::CloudFormation.new(aws_config)
          else
            Hiera.debug('No AWS configuration found, will fall back to env variables or IAM role')
            @cf = AWS::CloudFormation.new
          end
        else
          Hiera.debug('No configuration found, will fall back to env variables or IAM role')
          @cf = AWS::CloudFormation.new
        end

        @output_cache = Cache.new('output')
        @resource_cache = Cache.new('resource')

        Hiera.debug('Hiera cloudformation backend loaded')
      end

      def lookup(key, scope, order_override, resolution_type)
        answer = nil

        Backend.datasources(scope, order_override) do |elem|
          case elem
          when %r{cfstack/([^/]+)/outputs}
            Hiera.debug("Looking up #{key} as an output of stack #{$1}")
            raw_answer = stack_output_query($1, key)
          when %{cfstack/([^/]+)/resources/([^/]+)}
            Hiera.debug("Looking up #{key} in metadata of stack #{$1} resource #{$2}")
            raw_answer = stack_resource_query($1, $2, key)
          else
            Hiera.debug("#{elem} doesn't seem to be a CloudFormation hierarchy element")
            next
          end

          next if raw_answer.nil?
          raw_answer = convert_metadata(raw_answer) if @parse_metadata
          new_answer = Backend.parse_answer(raw_answer, scope)

          case resolution_type
          when :array
            fail Exception, "Hiera type mismatch: expected Array and got #{new_answer.class}" unless new_answer.is_a?(Array) || new_answer.is_a?(String)
            answer ||= []
            answer << new_answer
          when :hash
            fail Exception, "Hiera type mismatch: expected Hash and got #{new_answer.class}" unless new_answer.is_a? Hash
            answer ||= {}
            answer = Backend.merge_answer(new_answer, answer)
          else
            answer = new_answer
            break
          end
        end
      end

      def stack_output_query(stack_name, key)
        outputs = @output_cache.get(stack_name)

        if outputs.nil?
          Hiera.debug("#{stack_name} outputs not cached, fetching...")
          begin
            outputs = @cf.stacks[stack_name].outputs
          rescue AWS::CloudFormation::Errors::ValidationError
            Hiera.debug("Stack #{stack_name} outputs can't be retrieved")
            outputs = []  # this is just a non-nil value to serve as marker in cache
          end
          @output_cache.put(stack_name, outputs, TIMEOUT)
        end

        output = outputs.select { |item| item.key == key }

        output.empty? ? nil : output.shift.value
      end

      def stack_resource_query(stack_name, resource_id, key)
        metadata = @resource_cache.get({ :stack => stack_name, :resource => resource_id })

        if metadata.nil?
          Hiera.debug("#{stack_name} #{resource_id} metadata not cached, fetching")
          begin
            metadata = @cf.stacks[stack_name].resources[resource_id].metadata
          rescue AWS::CloudFormation::Errors::ValidationError
            # Stack or resource doesn't exist
            Hiera.debug("Stack #{stack_name} resource #{resource_id} can't be retrieved")
            metadata = '{}' # This is just a non-nil value to serve as marker in cache
          end
          @resource_cache.put({ :stack => stack_name, :resource => resource_id }, metadata, TIMEOUT)
        end

        if metadata.respond_to?(:to_str)
          data = JSON.parse(metadata)

          if data.include?('hiera')
            return data['hiera'][key] if data['hiera'].include?(key)
          end
        end

        nil
      end

      def convert_metadata(json_object)
        if json_object.is_a?(Hash)
          # convert each value of a Hash
          converted_object = {}
          json_object.each do |key, value|
            converted_object[key] = convert_metadata(value)
          end
          return converted_object
        elsif json_object.is_a?(Array)
          # convert each item in an Array
          return json_object.map { |item| convert_metadata(item) }
        elsif json_object == 'true'
          # Boolean literals
          return true
        elsif json_object == 'false'
          return false
        elsif json_object == 'null'
          return nil
        elsif /^-?([1-9]\d*|0)(.\d+)?([eE][+-]?\d+)?$/.match(json_object)
          # Numeric literals
          if json_object.include?('.')
            return json_object.to_f
          else
            return json_object.to_i
          end
        else
          return json_object
        end
      end
    end
  end
end
