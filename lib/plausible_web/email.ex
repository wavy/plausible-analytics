defmodule PlausibleWeb.Email do
  use Bamboo.Phoenix, view: PlausibleWeb.EmailView
  import Bamboo.PostmarkHelper

  def mailer_email_from do
    Application.get_env(:plausible, :mailer_email)
  end

  def activation_email(user, code) do
    base_email()
    |> to(user)
    |> tag("activation-email")
    |> subject("#{code} is your Plausible email verification code")
    |> render("activation_email.html", user: user, code: code)
  end

  def welcome_email(user) do
    base_email()
    |> to(user)
    |> tag("welcome-email")
    |> subject("Welcome to Plausible")
    |> render("welcome_email.html", user: user)
  end

  def create_site_email(user) do
    base_email()
    |> to(user)
    |> tag("create-site-email")
    |> subject("Your Plausible setup: Add your website details")
    |> render("create_site_email.html", user: user)
  end

  def site_setup_help(user, site) do
    base_email()
    |> to(user)
    |> tag("help-email")
    |> subject("Your Plausible setup: Waiting for the first page views")
    |> render("site_setup_help_email.html", user: user, site: site)
  end

  def site_setup_success(user, site) do
    base_email()
    |> to(user)
    |> tag("setup-success-email")
    |> subject("Plausible is now tracking your website stats")
    |> render("site_setup_success_email.html", user: user, site: site)
  end

  def check_stats_email(user) do
    base_email()
    |> to(user)
    |> tag("check-stats-email")
    |> subject("Check your Plausible website stats")
    |> render("check_stats_email.html", user: user)
  end

  def password_reset_email(email, reset_link) do
    base_email()
    |> to(email)
    |> tag("password-reset-email")
    |> subject("Plausible password reset")
    |> render("password_reset_email.html", reset_link: reset_link)
  end

  def trial_one_week_reminder(user) do
    base_email()
    |> to(user)
    |> tag("trial-one-week-reminder")
    |> subject("Your Plausible trial expires next week")
    |> render("trial_one_week_reminder.html", user: user)
  end

  def trial_upgrade_email(user, day, {pageviews, custom_events}) do
    base_email()
    |> to(user)
    |> tag("trial-upgrade-email")
    |> subject("Your Plausible trial ends #{day}")
    |> render("trial_upgrade_email.html",
      user: user,
      day: day,
      custom_events: custom_events,
      usage: pageviews + custom_events
    )
  end

  def trial_over_email(user) do
    base_email()
    |> to(user)
    |> tag("trial-over-email")
    |> subject("Your Plausible trial has ended")
    |> render("trial_over_email.html", user: user)
  end

  def weekly_report(email, site, assigns) do
    base_email()
    |> to(email)
    |> tag("weekly-report")
    |> subject("#{assigns[:name]} report for #{site.domain}")
    |> render("weekly_report.html", Keyword.put(assigns, :site, site))
  end

  def spike_notification(email, site, current_visitors, sources, dashboard_link) do
    base_email()
    |> to(email)
    |> tag("spike-notification")
    |> subject("Traffic spike on #{site.domain}")
    |> render("spike_notification.html", %{
      site: site,
      current_visitors: current_visitors,
      sources: sources,
      link: dashboard_link
    })
  end

  def over_limit_email(user, usage, last_cycle) do
    base_email()
    |> to(user)
    |> tag("over-limit")
    |> subject("You have outgrown your Plausible subscription tier ")
    |> render("over_limit.html", %{
      user: user,
      usage: usage,
      last_cycle: last_cycle
    })
  end

  def yearly_renewal_notification(user) do
    date = Timex.format!(user.subscription.next_bill_date, "{Mfull} {D}, {YYYY}")

    base_email()
    |> to(user)
    |> tag("yearly-renewal")
    |> subject("Your Plausible subscription is up for renewal")
    |> render("yearly_renewal_notification.html", %{
      user: user,
      date: date,
      next_bill_amount: user.subscription.next_bill_amount
    })
  end

  def yearly_expiration_notification(user) do
    date = Timex.format!(user.subscription.next_bill_date, "{Mfull} {D}, {YYYY}")

    base_email()
    |> to(user)
    |> tag("yearly-expiration")
    |> subject("Your Plausible subscription is about to expire")
    |> render("yearly_expiration_notification.html", %{
      user: user,
      date: date,
      next_bill_amount: user.subscription.next_bill_amount
    })
  end

  def cancellation_email(user) do
    base_email()
    |> to(user.email)
    |> tag("cancelled-email")
    |> subject("Your Plausible Analytics subscription has been canceled")
    |> render("cancellation_email.html", name: user.name)
  end

  defp base_email() do
    mailer_from = Application.get_env(:plausible, :mailer_email)

    new_email()
    |> put_param("TrackOpens", false)
    |> from(mailer_from)
  end
end
