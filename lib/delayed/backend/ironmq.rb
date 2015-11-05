module Delayed
  module Backend
    module Ironmq
      class Job
        include ::DelayedJobIronmq::Document
        include Delayed::Backend::Base
        extend  Delayed::Backend::Ironmq::Actions

        EXTRA_MESSAGE_TIMEOUT = 5

        field :priority,    :type => Integer, :default => 0
        field :attempts,    :type => Integer, :default => 0
        field :handler,     :type => String
        field :run_at,      :type => Time
        field :locked_at,   :type => Time
        field :locked_by,   :type => String
        field :failed_at,   :type => Time
        field :last_error,  :type => String
        field :queue,       :type => String
        field :created_at,  :type => Time

        def initialize(data = {})
          @msg = nil
          if data.is_a?(IronMQ::Message)
            @msg = data
            data = JSON.load(data.body)
          end

          data.symbolize_keys!
          payload_obj = data.delete(:payload_object) || data.delete(:handler)

          @default_queue   = data[:default_queue]   || IronMqBackend.default_queue
          @delay           = data[:delay]           || IronMqBackend.delay
          @expires_in      = data[:expires_in]      || IronMqBackend.expires_in
          @error_queue     = data[:error_queue]     || IronMqBackend.error_queue
          @max_run_time    = data[:max_run_time]    || Worker.max_run_time
          @attributes    = data
          self.payload_object = payload_obj

          initialize_queue
        end

        def self.reserve(worker, max_run_time = Worker.max_run_time)
          find_available(worker, max_run_time)
        end

        def self.find_available(worker, max_run_time = Worker.max_run_time)
          Delayed::IronMqBackend.available_priorities.each do |priority|
            Delayed::IronMqBackend.all_queues(worker).each do |queue_item|
              message = nil
              queue = queue_name(queue_item, priority)
              begin
                message = ironmq.queue(queue).get
              rescue StandardError => e
                if e.is_a?(Rest::HttpError) && e.code == 404
                  # suppress Not Found errors
                else
                  Delayed::IronMqBackend.logger.warn(e.message)
                end
              end
              return Delayed::Backend::Ironmq::Job.new(message) if message
            end
          end
          nil
        end

        def self.delete_all
          Delayed::IronMqBackend.available_priorities.each do |priority|
            loop do
              msgs = nil
              Delayed::IronMqBackend.queues.each do |queue_item|
                queue = queue_name(queue_item, priority)
                begin
                  msgs = ironmq.queue(queue).get(:n => 100)
                rescue StandardError => e
                  if e.is_a?(Rest::HttpError) && e.code == 404
                    # suppress Not Found errors
                  else
                    Delayed::IronMqBackend.logger.warn(e.message)
                  end
                end

                break if msgs.blank?
                ironmq.queue(queue).delete_reserved_messages(msgs)
              end

            end
          end
        end

        def payload_object
          @payload_object ||= yaml_load
        rescue TypeError, LoadError, NameError, ArgumentError => e
          raise DeserializationError,
            "Job failed to load: #{e.message}. Handler: #{handler.inspect}"
        end

        def payload_object=(object)
          if object.is_a? String
            @payload_object = yaml_load(object)
            self.handler = object
          else
            @payload_object = object
            self.handler = object.to_yaml
          end
        end

        def save
          if @attributes[:handler].blank?
            raise "Handler missing!"
          end
          payload = JSON.dump(@attributes)

          if run_at && run_at.utc >= self.class.db_time_now
            @delay = (run_at.utc - self.class.db_time_now).round
          end

          @msg.delete if @msg

          ironmq.queue(queue_name).post(payload, delay: @delay)
          true
        end

        def save!
          save
        end

        def destroy
          @msg.delete if @msg
        rescue StandardError => e # reget message and remove if timeouted
          IronMqBackend.logger.warn(e.message)
          msg = ironmq.queue(queue_name).get_message(@msg.id)
          msg.delete
        end

        def fail!
          ironmq.queue(@error_queue).post(@msg.body, delay: @delay)
          destroy
        end

        def update_attributes(attributes)
          attributes.symbolize_keys!
          @attributes.merge attributes
          save
        end

        # No need to check locks
        def lock_exclusively!(*args)
          true
        end

        # No need to check locks
        def unlock(*args)
        end

        def reload(*args)
          # reset
          super
        end

        def id
          @msg.id if @msg
        end

        private

        def queue_name
          "#{@attributes[:queue] || @default_queue}_#{@attributes[:priority] || 0}"
        end

        def ironmq
          ::Delayed::IronMqBackend.ironmq
        end

        def yaml_load(object)
          object ||= self.handler
          YAML.respond_to?(:load_dj) ? YAML.load_dj(object) : YAML.load(object)
        end

        def initialize_queue
          ironmq.queue(queue_name).info
        rescue
          ironmq.create_queue(queue_name, message_timeout: @max_run_time.to_i + EXTRA_MESSAGE_TIMEOUT,
                                          message_expiration: @expires_in.to_i)
        end
      end
    end
  end
end
