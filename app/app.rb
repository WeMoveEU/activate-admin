module ActivateAdmin
  class OperatorNotSupported < StandardError; end
  class App < Padrino::Application
    register Padrino::Rendering
    register Padrino::Helpers
    register WillPaginate::Sinatra
    helpers Activate::DatetimeHelpers
    helpers Activate::ParamHelpers
    helpers Activate::NavigationHelpers

    enable :sessions

    if ENV['SSL']
      use Rack::SslEnforcer
      use Rack::Session::Cookie, :key => '_rack_session', :path => '/', :expire_after => 30*24*60*60, :secret => ENV['SESSION_SECRET']
    else
      set :sessions, :expire_after => 1.year
    end

    def initialize
      unless ActiveRecord::Base.connection.active?
        if ENV['DATABASE_URL'] and ENV['DATABASE_SCHEMA']
          ActiveRecord::Base.establish_connection(ENV['DATABASE_URL'])
          ActiveRecord::Base.connection.schema_search_path = ENV['DATABASE_SCHEMA']
        else
          raise "No database URL or schema set in environment variable. ActivateAdmin may perform weirdly or break."
        end
      end
      super
    end

    set :show_exceptions, true
    set :public_folder,  ActivateAdmin.root('app', 'assets')
    set :default_builder, 'ActivateFormBuilder'

    before do
      if ENV['PERMITTED_IPS'] and Padrino.env == :production
        if !ENV['CLIENT_IP_HEADER']
          ip_to_verify = request.ip
        else
          rack_header_name = "HTTP_#{ENV['CLIENT_IP_HEADER'].upcase.gsub!('-', '_')}"
          ip_to_verify = request.env[rack_header_name]
        end
        halt 403 unless ENV['PERMITTED_IPS'].split(',').include? ip_to_verify
      end
      redirect url(:login) + "?redir=#{CGI::escape request.path}" unless [url(:login), url(:logout), url(:forgot_password)].any? { |p| p == request.path } or ['stylesheets','javascripts'].any? { |p| request.path.starts_with? "#{ActivateAdmin::App.uri_root}/#{p}" } or Account.count == 0 or (current_account and current_account.admin?)
      Time.zone = current_account.time_zone if current_account and current_account.respond_to?(:time_zone) and current_account.time_zone
      fix_params!
    end

    get :home, :map => '/' do
      erb :home
    end

    get :config, :map => '/config' do
      erb :config
    end

    post :config, :map => '/config' do
      heroku = PlatformAPI.connect_oauth(ENV['HEROKU_OAUTH_TOKEN'])
      heroku.config_var.update(ENV['APP_NAME'], Hash[heroku.config_var.info(ENV['APP_NAME']).map { |k,v| [k, params[k]] }])
      flash[:notice] = "Your config vars were updated. You may have to refresh the page for your changes to take effect."
      redirect url(:config)
    end

    get :index, :map => '/index/:model', :provides => [:html, :json, :csv] do
      if persisted_field?(model, :created_at)
        @o = :created_at
        @d = :desc
      end
      if model.respond_to?(:filter_options)
        @o, @d = model.filter_options[:o], model.filter_options[:d]
      end
      @id = params[:id] if params[:id]
      @q = params[:q] if params[:q]
      @o = params[:o].to_sym if params[:o]
      @d = params[:d].to_sym if params[:d]
      @resources = model.all
      @resources = @resources.where(id: @id) if @id

      if @q
        query = []
        admin_fields(model).each { |fieldname, options|
          if options[:type] === :lookup
            assoc_name = assoc_name(model, fieldname)
            assoc_model = assoc_name.constantize
            assoc_fields = admin_fields(assoc_model)
            assoc_fieldname = lookup_method(assoc_model)
            assoc_options = assoc_fields[assoc_fieldname]
            if persisted_field?(assoc_model, assoc_fieldname)
              if matchable_regex.include?(assoc_options[:type])
                if active_record?
                  query << ["#{fieldname} in (?)", assoc_model.where(["#{assoc_fieldname} ilike ?", "%#{@q}%"]).select(:id)]
                elsif mongoid?
                  query << {fieldname.to_sym.in => assoc_model.where(assoc_fieldname => /#{Regexp.escape(@q)}/i).pluck(:id) }
                end
              elsif matchable_number.include?(assoc_options[:type]) and (begin; Float(@q) and true; rescue; false; end)
                if active_record?
                  query << ["#{fieldname} in (?)", assoc_model.where(assoc_fieldname => @q).select(:id)]
                elsif mongoid?
                  query << {fieldname.to_sym.in => assoc_model.where(assoc_fieldname => @q).pluck(:id) }
                end
              end
            end
          elsif persisted_field?(model, fieldname)
            if matchable_regex.include?(options[:type])
              if active_record?
                query << ["#{fieldname} ilike ?", "%#{@q}%"]
              elsif mongoid?
                query << {fieldname => /#{Regexp.escape(@q)}/i }
              end
            elsif matchable_number.include?(options[:type]) and (begin; Float(@q) and true; rescue; false; end)
              query << {fieldname => @q}
            end
          end
        }
        if active_record?
          if !query.empty?
            head, *tail = query
            sub_resources = @resources.where(head) # add at least one concrete condition
            tail.each do |cond|
              sub_resources = sub_resources.or(@resources.where(cond))
            end
            @resources = sub_resources
          end
        elsif mongoid?
          @resources = @resources.or(query)
        end
      end

      query = []
      params[:qk].each_with_index { |fieldname,i|
        q = params[:qv][i]
        b = params[:qb][i].to_sym
        if !fieldname.include?('.')
          collection_model = model
          collection_key = :id
        else
          collection, fieldname = fieldname.split('.')
          collection_assoc = assoc(model, collection, relationship: :has_many)
          collection_model = collection_assoc.class_name.constantize
          collection_key = collection_assoc.inverse_foreign_key.to_sym
        end
        options = admin_fields(collection_model)[fieldname.to_sym]
        if options[:type] == :lookup
          case b
          when :is, :in
            if active_record?
              query << ["id in (?)", collection_model.where(fieldname => q).select(collection_key)]
            elsif mongoid?
              query << {:id.in => collection_model.where(fieldname => q).pluck(collection_key)}
            end
          when :nin
            if active_record?
              query << ["id not in (?)", collection_model.where(fieldname => q).select(collection_key)]
            elsif mongoid?
              query << {:id.nin => collection_model.where(fieldname => q).pluck(collection_key)}
            end
          when :gt, :gte, :lt, :lte
            raise OperatorNotSupported
          end
        elsif persisted_field?(collection_model, fieldname)
          if matchable_regex.include?(options[:type])
            case b
            when :is
              if active_record?
                query << ["id in (?)", collection_model.where(["#{fieldname} = ?", q]).select(collection_key)]
              elsif mongoid?
                query << {:id.in => collection_model.where(fieldname => /#{Regexp.escape(q)}/i).pluck(collection_key)}
              end
            when :in
              if active_record?
                query << ["id in (?)", collection_model.where(["#{fieldname} ilike ?", "%#{q}%"]).select(collection_key)]
              elsif mongoid?
                query << {:id.in => collection_model.where(fieldname => /#{Regexp.escape(q)}/i).pluck(collection_key)}
              end
            when :nin
              if active_record?
                query << ["id not in (?)", collection_model.where(["#{fieldname} ilike ?", "%#{q}%"]).select(collection_key)]
              elsif mongoid?
                query << {:id.nin => collection_model.where(fieldname => /#{Regexp.escape(q)}/i).pluck(collection_key)}
              end
            when :gt, :gte, :lt, :lte
              raise OperatorNotSupported
            end
          elsif matchable_number.include?(options[:type]) and (begin; Float(q) and true; rescue; false; end)
            case b
            when :in
              if active_record?
                query << ["id in (?)", collection_model.where(fieldname => q).select(collection_key)]
              elsif mongoid?
                query << {:id.in => collection_model.where(fieldname => q).pluck(collection_key)}
              end
            when :is, :nin
              if active_record?
                query << ["id not in (?)", collection_model.where(fieldname => q).select(collection_key)]
              elsif mongoid?
                query << {:id.nin => collection_model.where(fieldname => q).pluck(collection_key)}
              end
            when :gt, :gte, :lt, :lte
              if active_record?
                query << ["id in (?)", collection_model.where(["#{fieldname} #{inequality(b)} ?", q]).select(collection_key)]
              elsif mongoid?
                query << {:id.in => collection_model.where(fieldname.to_sym.send(b) => q).pluck(collection_key)}
              end
            end
          elsif options[:type] == :geopicker
            case b
            when :is, :in
              if active_record?
                # TODO
                raise OperatorNotSupported
              elsif mongoid?
                query << {:id.in => collection_model.where(:coordinates => { "$geoWithin" => { "$centerSphere" => [Geocoder.coordinates(q.split(':')[0].strip).reverse, ((d = q.split(':')[1]) ? d.strip.to_i : 20) / 3963.1676 ]}}).pluck(collection_key)}
              end
            when :nin
              if active_record?
                # TODO
                raise OperatorNotSupported
              elsif mongoid?
                query << {:id.nin => collection_model.where(:coordinates => { "$geoWithin" => { "$centerSphere" => [Geocoder.coordinates(q.split(':')[0].strip).reverse, ((d = q.split(':')[1]) ? d.strip.to_i : 20) / 3963.1676 ]}}).pluck(collection_key)}
              end
            when :gt, :gte, :lt, :lte
              raise OperatorNotSupported
            end
          elsif options[:type] == :check_box
            case b
            when :is, :in
              if active_record?
                query << ["id in (?)", collection_model.where(fieldname => (q == 'true')).select(collection_key)]
              elsif mongoid?
                query << {:id.in => collection_model.where(fieldname => (q == 'true')).pluck(collection_key)}
              end
            when :nin
              if active_record?
                query << ["id not in (?)", collection_model.where(fieldname => (q == 'true')).select(collection_key)]
              elsif mongoid?
                query << {:id.nin => collection_model.where(fieldname => (q == 'true')).pluck(collection_key)}
              end
            when :gt, :gte, :lt, :lte
              raise OperatorNotSupported
            end
          elsif options[:type] == :date
            case b
            when :is, :in
              if active_record?
                query << ["id in (?)", collection_model.where(fieldname => Date.parse(q)).select(collection_key)]
              elsif mongoid?
                query << {:id.in => collection_model.where(fieldname => Date.parse(q)).pluck(collection_key)}
              end
            when :nin
              if active_record?
                query << ["id not in (?)", collection_model.where(fieldname => Date.parse(q)).select(collection_key)]
              elsif mongoid?
                query << {:id.nin => collection_model.where(fieldname => Date.parse(q)).pluck(collection_key)}
              end
            when :gt, :gte, :lt, :lte
              if active_record?
                query << ["id in (?)", collection_model.where(["#{fieldname} #{inequality(b)} ?", Date.parse(q)]).select(collection_key)]
              elsif mongoid?
                query << {:id.in => collection_model.where(fieldname.to_sym.send(b) => Date.parse(q)).pluck(collection_key)}
              end
            end
          elsif options[:type] == :datetime
            case b
            when :is, :in
              if active_record?
                query << ["id in (?)", collection_model.where(fieldname => Time.zone.parse(q)).select(collection_key)]
              elsif mongoid?
                query << {:id.in => collection_model.where(fieldname => Time.zone.parse(q)).pluck(collection_key)}
              end
            when :nin
              if active_record?
                query << ["id not in (?)", collection_model.where(fieldname => Time.zone.parse(q)).select(collection_key)]
              elsif mongoid?
                query << {:id.nin => collection_model.where(fieldname => Time.zone.parse(q)).pluck(collection_key)}
              end
            when :gt, :gte, :lt, :lte
              if active_record?
                query << ["id in (?)", collection_model.where(["#{fieldname} #{inequality(b)} ?", Time.zone.parse(q)]).select(collection_key)]
              elsif mongoid?
                query << {:id.in => collection_model.where(fieldname.to_sym.send(b) => Time.zone.parse(q)).pluck(collection_key)}
              end
            end
          end
        end
      } if params[:qk]

      case params[:all_any]
      when 'all'
        if active_record?
          query.each { |q| @resources = @resources.where(q) }
        elsif mongoid?
          @resources = @resources.all_of(query)
        end
      when 'any'
        if active_record?
          if !query.empty?
            head, *tail = query
            sub_resources = @resources.where(head) # add at least one concrete condition
            tail.each do |cond|
              sub_resources = sub_resources.or(@resources.where(cond))
            end
            @resources = sub_resources
          end
        elsif mongoid?
          @resources = @resources.or(query)
        end
      end

      if @o and @d
        @resources = @resources.order("#{@o} #{@d}")
      end
      case content_type
      when :html
        @resources = @resources.paginate(:page => params[:page], :per_page => 25)
        instance_variable_set("@#{model.to_s.underscore.pluralize}", @resources)
        erb :index
      when :json
        {
          results: @resources.map { |resource| {id: resource.id.to_s, text: "#{resource.send(lookup_method(resource.class))} (id:#{resource.id})"} }
        }.to_json
      when :csv
        fields = admin_fields(model).select { |fieldname, options| options[:index] }
        CSV.generate do |csv|
          csv << fields.keys
          @resources.each do |resource|
            csv << fields.map { |fieldname, options|
              if options[:type] === :lookup and resource.send(fieldname)
                assoc_name = assoc_name(model, fieldname)
                "#{assoc_name.constantize.find(resource.send(fieldname)).send(lookup_method(assoc_name.constantize))} (id:#{resource.send(fieldname)})"
              else
                resource.send(fieldname)
              end
            }
          end
        end
      end
    end

    get :new, :map => '/new/:model' do
      @resource = model.new
      instance_variable_set("@#{model.to_s.underscore}", @resource)
      erb :build
    end

    post :new, :map => '/new/:model', :provides => [:html, :json] do
      @resource = model.new(params[model.to_s.underscore])
      instance_variable_set("@#{model.to_s.underscore}", @resource)
      if @resource.save
        case content_type
        when :html
          if !params[:popup]
            flash[:notice] = "<strong>Sweet!</strong> The #{human_model_name(model).downcase} was created successfully."
          end
          params[:popup] ? closePopup : redirect(url(:edit, :model => model.to_s, :id => @resource.id))
        when :json
          {url: @resource.send(ENV['INLINE_UPLOAD_MODEL_FILE_FIELD']).url}.to_json
        end
      else
        case content_type
        when :html
          flash.now[:error] = "<strong>Oops.</strong> Some errors prevented the #{human_model_name(model).downcase} from being saved."
          erb :build
        when :json
          error
        end
      end
    end

    get :edit, :map => '/edit/:model/:id' do
      @resource = model.find(params[:id])
      instance_variable_set("@#{model.to_s.underscore}", @resource)
      erb :build
    end

    post :edit, :map => '/edit/:model/:id' do
      @resource = model.find(params[:id])
      instance_variable_set("@#{model.to_s.underscore}", @resource)
      if @resource.update_attributes(params[model.to_s.underscore])
        if !params[:popup]
          flash[:notice] = "<strong>Sweet!</strong> The #{human_model_name(model).downcase} was updated successfully."
        end
        params[:popup] ? closePopup : redirect(url(:edit, :model => model.to_s, :id => @resource.id))
      else
        flash.now[:error] = "<strong>Oops.</strong> Some errors prevented the #{human_model_name(model).downcase} from being saved."
        erb :build
      end
    end

    get :destroy, :map => '/destroy/:model/:id' do
      resource = model.find(params[:id])
      if resource.destroy
        if !params[:popup]
          flash[:notice] = "<strong>Boom!</strong> The #{human_model_name(model).downcase} was deleted."
        end
      else
        if !params[:popup]
          flash[:error] = "<strong>Darn!</strong> The #{human_model_name(model).downcase} couldn't be deleted."
        end
      end
      params[:popup] ? closePopup : redirect(url(:index, :model => model.to_s))
    end

    get :login, :map => '/login' do
      erb :login
    end

    post :login, :map => '/login' do
      if account = Account.authenticate(params[:email], params[:password])
        session[:account_id] = account.id
        flash[:notice] = "Logged in successfully."
        redirect url(:home)
      elsif Padrino.env == :development && params[:bypass]
        account = Account.first
        session[:account_id] = account.id
        flash[:notice] = "Logged in successfully."
        redirect params[:redir] or url(:home)
      else
        flash[:error] = "Login or password wrong."
        redirect url(:login)
      end
    end

    get :logout, :map => '/logout' do
      session.clear
      redirect url(:login)
    end

    post :forgot_password, :map => '/forgot_password' do
      if active_record?
        account = Account.where('email ilike ?', params[:email]).first
      elsif mongoid?
        account = Account.find_by(email: /^#{Regexp.escape(params[:email])}$/i)
      end
      if account.present?
        account.reset_password!
      else
        Padrino.logger.warn("Someone tried to log in with a non-existant email: #{params[:email]}")
      end
      flash[:notice] = "If an account with the email #{params[:email]} exists, you'll receive instructions on what to do next"
      redirect url(:login)
    end

  end
end
