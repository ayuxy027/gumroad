# frozen_string_literal: true

class LoginsController < Devise::SessionsController
  include OauthApplicationConfig, ValidateRecaptcha, InertiaRendering

  include PageMeta::Base

  skip_before_action :check_suspended
  before_action :block_json_request, only: :new
  after_action :clear_dashboard_preference, only: :destroy
  before_action :reset_impersonated_user, only: :destroy
  before_action :set_noindex_header, only: :new, if: -> { params[:next]&.start_with?("/oauth/authorize") }

  before_action :set_csrf_meta_tags
  before_action :set_default_meta_tags
  helper_method :erb_meta_tags

  layout "inertia", only: [:new]

  def new
    return redirect_to login_path(next: request.referrer) if params[:next].blank? && request_referrer_is_a_valid_after_login_path?

    set_meta_tag(title: "Log In")
    auth_presenter = AuthPresenter.new(params:, application: @application)
    render inertia: "Logins/New", props: auth_presenter.login_props.merge(is_gumroad_mobile_app: cookies[:is_gumroad_mobile_app].present?)
  end

  def create
    unless Feature.active?(:disable_login_recaptcha)
      site_key = GlobalConfig.get("RECAPTCHA_LOGIN_SITE_KEY")
      if !(Rails.env.development? && site_key.blank?) && !valid_recaptcha_response?(site_key: site_key)
        return redirect_with_login_error("Sorry, we could not verify the CAPTCHA. Please try again.")
      end
    end

    if params["user"].instance_of?(ActionController::Parameters)
      # Strip UTF-16 NULs and surrounding whitespace before lookup. Some mobile keyboards
      # (and copy/paste flows) inject \u0000 which silently breaks exact-match queries
      # against indexed columns and causes "account does not exist" for valid users.
      login_identifier = params["user"]["login_identifier"]&.gsub("\u0000", "")&.strip
      password = params["user"]["password"]
      @user = User.where(email: login_identifier).first || User.where(username: login_identifier).first if login_identifier.present?
    end

    return redirect_with_login_error("An account does not exist with that email.") if @user.blank?

    return redirect_with_login_error("Please try another password. The one you entered was incorrect.") unless @user.valid_password?(password)

    return redirect_with_login_error("You cannot log in because your account was permanently deleted. Please sign up for a new account to start selling!") if @user.deleted?

    @user.remember_me = true # Always "remember" user sessions

    sign_in_or_prepare_for_two_factor_auth(@user)

    if @user.respond_to?(:pwned?) && @user.pwned?
      flash[:warning] = "Your password has previously appeared in a data breach as per haveibeenpwned.com and should never be used. We strongly recommend you change your password everywhere you have used it."
    end

    path = login_path_for(@user)
    # When login is submitted via Inertia XHR and the post-login destination is the
    # OAuth authorize endpoint (mobile app sign-in flow), a normal redirect_to returns
    # a 302 that Inertia tries to follow as XHR — and OAuth's HTML response breaks it.
    # inertia_location forces a full browser navigation so the OAuth page renders.
    if request.inertia? && path.start_with?("/oauth/authorize")
      inertia_location(path)
    else
      redirect_to path, allow_other_host: true
    end
  end

  private
    def block_json_request
      return if request.inertia?

      head :bad_request if request.format.json?
    end

    def redirect_with_login_error(message)
      redirect_to login_path, warning: message, status: :see_other
    end
end
