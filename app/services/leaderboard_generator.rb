class LeaderboardGenerator
  include TimezoneRegions

  def self.generate_timezone_offset_leaderboard(date, utc_offset, period_type = :daily)
    new.generate_timezone_offset_leaderboard(date, utc_offset, period_type)
  end

  def self.generate_timezone_leaderboard(date, timezone, period_type = :daily)
    new.generate_timezone_leaderboard(date, timezone, period_type)
  end

  def generate_timezone_offset_leaderboard(date, utc_offset, period_type = :daily)
    date = Date.current if date.blank?
    users = User.users_in_timezone_offset(utc_offset).not_convicted
    generate_leaderboard_for_users(users, date, "UTC#{utc_offset >= 0 ? '+' : ''}#{utc_offset}", period_type)
  end

  def generate_timezone_leaderboard(date, timezone, period_type = :daily)
    date = Date.current if date.blank?
    users = User.users_in_timezone(timezone).not_convicted
    generate_leaderboard_for_users(users, date, timezone, period_type)
  end

  private

  def generate_leaderboard_for_users(users, date, scope_name, period_type = :daily)
    # Ensure date is valid
    date = Date.current if date.blank?

    # Create a virtual leaderboard object (not saved to DB)
    leaderboard = Leaderboard.new(
      start_date: date,
      period_type: period_type,
      finished_generating_at: Time.current
    )

    # Get user IDs
    user_ids = users.pluck(:id)
    return leaderboard if user_ids.empty?

    # Calculate heartbeats for the date range in UTC
    date_range = case period_type
    when :weekly
      date.beginning_of_week.beginning_of_day..date.end_of_week.end_of_day
    when :last_7_days
      (date - 6.days).beginning_of_day..Date.current.end_of_day
    else
      date.all_day
    end

    # Get heartbeats for these users
    heartbeats = Heartbeat.where(user_id: user_ids, time: date_range)
                         .coding_only
                         .with_valid_timestamps
                         .joins(:user)
                         .where.not(users: { github_uid: nil })

    # Group by user and calculate totals
    user_totals = heartbeats.group(:user_id).duration_seconds
    user_totals = user_totals.filter { |_, total_seconds| total_seconds > 60 }

    # Get streaks for all users at once
    streaks = Heartbeat.daily_streaks_for_users(user_totals.keys) if user_totals.any?

    # Create virtual leaderboard entries
    entries = user_totals.map do |user_id, total_seconds|
      entry = LeaderboardEntry.new(
        leaderboard: leaderboard,
        user_id: user_id,
        total_seconds: total_seconds,
        streak_count: streaks[user_id] || 0
      )

      # Manually set the user association to avoid N+1 queries
      entry.user = users.find { |u| u.id == user_id }
      entry
    end.sort_by(&:total_seconds).reverse

    # Attach entries to leaderboard
    leaderboard.define_singleton_method(:entries) { entries }
    leaderboard.define_singleton_method(:scope_name) { scope_name }

    leaderboard
  end
end
