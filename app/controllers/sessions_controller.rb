class SessionsController < ApplicationController
  def new
    redirect_uri = url_for(action: :create, only_path: false)
    Rails.logger.info "Starting Slack OAuth flow with redirect URI: #{redirect_uri}"
    redirect_to User.authorize_url(redirect_uri, close_window: params[:close_window].present?),
                host: "https://slack.com",
                allow_other_host: "https://slack.com"
  end

  def create
    redirect_uri = url_for(action: :create, only_path: false)

    if params[:error].present?
      Rails.logger.error "Slack OAuth error: #{params[:error]}"
      redirect_to root_path, alert: "Failed to authenticate with Slack"
      return
    end

    @user = User.from_slack_token(params[:code], redirect_uri)

    if @user&.persisted?
      session[:user_id] = @user.id

      if @user.data_migration_jobs.empty?
        # if they don't have a data migration job, add one to the queue
        OneTime::MigrateUserFromHackatimeJob.perform_later(@user.id)
      end

      state = JSON.parse(params[:state]) rescue {}
      if state["close_window"]
        redirect_to close_window_path
      else
        redirect_to root_path, notice: "Successfully signed in with Slack!"
      end
    else
      Rails.logger.error "Failed to create/update user from Slack data"
      redirect_to root_path, alert: "Failed to sign in with Slack"
    end
  end

  def close_window
    render :close_window, layout: false
  end

  def github_new
    unless current_user
      redirect_to root_path, alert: "Please sign in first to link your GitHub account"
      return
    end

    redirect_uri = url_for(action: :github_create, only_path: false)
    Rails.logger.info "Starting GitHub OAuth flow with redirect URI: #{redirect_uri}"
    redirect_to User.github_authorize_url(redirect_uri),
                allow_other_host: "https://github.com"
  end

  def github_create
    unless current_user
      redirect_to root_path, alert: "Please sign in first to link your GitHub account"
      return
    end

    redirect_uri = url_for(action: :github_create, only_path: false)

    if params[:error].present?
      Rails.logger.error "GitHub OAuth error: #{params[:error]}"
      redirect_to root_path, alert: "Failed to authenticate with GitHub"
      return
    end

    @user = User.from_github_token(params[:code], redirect_uri, current_user)

    if @user&.persisted?
      redirect_to root_path, notice: "Successfully linked GitHub account!"
    else
      Rails.logger.error "Failed to link GitHub account"
      redirect_to root_path, alert: "Failed to link GitHub account"
    end
  end

  def email
    email = params[:email].downcase

    if Rails.env.production?
      HandleEmailSigninJob.perform_later(email)
    else
      HandleEmailSigninJob.perform_now(email)
    end

    redirect_to root_path(sign_in_email: true), notice: "Check your email for a sign-in link!"
  end

  def token
    valid_token = SignInToken.where(token: params[:token], used_at: nil)
                            .where("expires_at > ?", Time.current)
                            .first

    if valid_token
      valid_token.mark_used!
      session[:user_id] = valid_token.user_id
      redirect_to root_path, notice: "Successfully signed in!"
    else
      redirect_to root_path, alert: "Invalid or expired sign-in link"
    end
  end

  def impersonate
    unless current_user.admin?
      redirect_to root_path, alert: "You are not authorized to impersonate users"
      return
    end

    session[:impersonater_user_id] ||= current_user.id
    user = User.find(params[:id])
    session[:user_id] = user.id
    redirect_to root_path, notice: "Impersonating #{user.username}"
  end

  def stop_impersonating
    session[:user_id] = session[:impersonater_user_id]
    session[:impersonater_user_id] = nil
    redirect_to root_path, notice: "Stopped impersonating"
  end

  def destroy
    session[:user_id] = nil
    session[:impersonater_user_id] = nil
    redirect_to root_path, notice: "Signed out!"
  end
end
