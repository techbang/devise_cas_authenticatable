class Devise::CasSessionsController < Devise::SessionsController
  include DeviseCasAuthenticatable::SingleSignOut::DestroySession
  unloadable if Rails::VERSION::MAJOR < 4 # Rails 5 no longer requires this

  # rails 5 unsupport skip_before_filter and skip_before_action need defined raise, see t18786
  if Rails::VERSION::MAJOR < 5
    skip_before_action :sync_fb_user
    skip_before_action :verify_authenticity_token, :only => [:single_sign_out]
  else
    skip_before_action :sync_fb_user, :raise => false
    skip_before_action :verify_authenticity_token, :only => [:single_sign_out], :raise => false
  end

  def new
    if memcache_checker.session_store_memcache? && !memcache_checker.alive?
      raise "memcache is down, can't get session data from it"
    end

    store_location!
    redirect_to(cas_login_url)
  end

  def service
    if cookies[:auth_token].present?
      if /buy.(staging.)?techbang/.match(request.host).present?
        redirect_to cas_user_facebook_omniauth_authorize_path
      else
        redirect_to user_facebook_omniauth_authorize_path
      end
    else
      warden.authenticate!(:scope => resource_name)
      redirect_to after_sign_in_path_for(resource_name)
    end
  end

  def unregistered
  end

  def destroy
    # if :cas_create_user is false a CAS session might be open but not signed_in
    # in such case we destroy the session here
    if signed_in?(resource_name)
      cookies.delete :auth_token, :domain => auth_token_domain
      cookies.delete :_trm, :domain => request.host.slice(/(staging.)*techbang.(com|test)$/)
      cookies.delete :_tun, :domain => request.host.slice(/(staging.)*techbang.(com|test)$/)

      store_location!

      sign_out(resource_name)
    else
      reset_session
    end

    redirect_to(cas_logout_url)
  end

  def single_sign_out
    if ::Devise.cas_enable_single_sign_out
      session_index = read_session_index
      if session_index
        logger.debug "Intercepted single-sign-out request for CAS session #{session_index}."
        session_id = ::DeviseCasAuthenticatable::SingleSignOut::Strategies.current_strategy.find_session_id_by_index(session_index)
        if session_id
          logger.debug "Found Session ID #{session_id} with index key #{session_index}"
          destroy_cas_session(session_index, session_id)
        end
      else
        logger.warn "Ignoring CAS single-sign-out request as no session index could be parsed from the parameters."
      end
    else
      logger.warn "Ignoring CAS single-sign-out request as feature is not currently enabled."
    end

    head :ok
  end

  private

  def auth_token_domain
    Rails.env.development? ? ".techbang.test" : ".techbang.com"
  end

  def read_session_index
    if request.headers['CONTENT_TYPE'] =~ %r{^multipart/}
      false
    elsif request.post? && params['logoutRequest'] =~
        %r{^<samlp:LogoutRequest.*?<samlp:SessionIndex>(.*)</samlp:SessionIndex>}m
      $~[1]
    else
      false
    end
  end

  def destroy_cas_session(session_index, session_id)
    if destroy_session_by_id(session_id)
      logger.debug "Destroyed session #{session_id} corresponding to service ticket #{session_index}."
    end
    ::DeviseCasAuthenticatable::SingleSignOut::Strategies.current_strategy.delete_session_index(session_index)
  end

  def cas_login_url
    ::Devise.cas_client.add_service_to_login_url(::Devise.cas_service_url(request.url, devise_mapping))
  end
  helper_method :cas_login_url

  def request_url
    return @request_url if @request_url
    @request_url = request.protocol.dup
    @request_url << request.host
    @request_url << ":#{request.port.to_s}" unless request.port == 80
    @request_url
  end

  def cas_destination_url
    return unless ::Devise.cas_logout_url_param == 'destination'
    if !::Devise.cas_destination_url.blank?
      url = Devise.cas_destination_url
    else
      url = !!(session["#{resource_name}_return_to"] =~ URI::regexp) ? "" : request_url.dup
      url << after_sign_out_path_for(resource_name)
    end
  end

  def cas_follow_url
    return unless ::Devise.cas_logout_url_param == 'follow'
    if !::Devise.cas_follow_url.blank?
      url = Devise.cas_follow_url
    else
      url = request_url.dup
      url << after_sign_out_path_for(resource_name)
    end
  end

  def cas_service_url
    ::Devise.cas_service_url(request_url.dup, devise_mapping)
  end

  def cas_logout_url
    begin
      ::Devise.cas_client.logout_url(cas_destination_url, cas_follow_url, cas_service_url)
    rescue ArgumentError
      # Older rubycas-clients don't accept a service_url
      ::Devise.cas_client.logout_url(cas_destination_url, cas_follow_url)
    end
  end

  def memcache_checker
    @memcache_checker ||= DeviseCasAuthenticatable::MemcacheChecker.new(Rails.configuration)
  end

  # Set `session[:user_return_to]` to the referer path unless it is already set.
  def store_location!
    session["#{resource_name}_return_to"] = referer_from_pcadv_url || stored_location_for(resource_name) || request_referer_path
  end

  def request_referer_path
    URI.parse(request.referer).path if request.referer
  end

  def referer_from_pcadv_url
    request.referer if request.referer && request.referer.match(/pcadv((\.|\-)staging)?\.techbang\.(test|com)/)
  end

end
