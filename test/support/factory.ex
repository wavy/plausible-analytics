defmodule Plausible.Factory do
  use ExMachina.Ecto, repo: Plausible.Repo

  def user_factory(attrs) do
    pw = Map.get(attrs, :password, "password")

    user = %Plausible.Auth.User{
      name: "Jane Smith",
      email: sequence(:email, &"email-#{&1}@example.com"),
      password_hash: Plausible.Auth.Password.hash(pw),
      trial_expiry_date: Timex.today() |> Timex.shift(days: 30),
      email_verified: true
    }

    merge_attributes(user, attrs)
  end

  def spike_notification_factory do
    %Plausible.Site.SpikeNotification{
      threshold: 10
    }
  end

  def site_factory do
    domain = sequence(:domain, &"example-#{&1}.com")

    %Plausible.Site{
      domain: domain,
      timezone: "UTC"
    }
  end

  def ch_session_factory do
    hostname = sequence(:domain, &"example-#{&1}.com")

    %Plausible.ClickhouseSession{
      sign: 1,
      session_id: SipHash.hash!(hash_key(), UUID.uuid4()),
      user_id: SipHash.hash!(hash_key(), UUID.uuid4()),
      hostname: hostname,
      domain: hostname,
      referrer: "",
      referrer_source: "",
      utm_medium: "",
      utm_source: "",
      utm_campaign: "",
      entry_page: "/",
      pageviews: 1,
      events: 1,
      duration: 0,
      start: Timex.now(),
      timestamp: Timex.now(),
      is_bounce: false,
      browser: "",
      browser_version: "",
      country_code: "",
      screen_size: "",
      operating_system: "",
      operating_system_version: ""
    }
  end

  def pageview_factory do
    struct!(
      event_factory(),
      %{
        name: "pageview"
      }
    )
  end

  def event_factory do
    hostname = sequence(:domain, &"example-#{&1}.com")

    %Plausible.ClickhouseEvent{
      hostname: hostname,
      domain: hostname,
      pathname: "/",
      timestamp: Timex.now(),
      user_id: SipHash.hash!(hash_key(), UUID.uuid4()),
      session_id: SipHash.hash!(hash_key(), UUID.uuid4()),
      referrer: "",
      referrer_source: "",
      utm_medium: "",
      utm_source: "",
      utm_campaign: "",
      browser: "",
      browser_version: "",
      country_code: "",
      screen_size: "",
      operating_system: "",
      operating_system_version: "",
      "meta.key": [],
      "meta.value": []
    }
  end

  def goal_factory do
    %Plausible.Goal{}
  end

  def subscription_factory do
    %Plausible.Billing.Subscription{
      paddle_subscription_id: sequence(:paddle_subscription_id, &"subscription-#{&1}"),
      paddle_plan_id: sequence(:paddle_plan_id, &"plan-#{&1}"),
      cancel_url: "cancel.com",
      update_url: "cancel.com",
      status: "active",
      next_bill_amount: "6.00",
      next_bill_date: Timex.today()
    }
  end

  def google_auth_factory do
    %Plausible.Site.GoogleAuth{
      email: sequence(:google_auth_email, &"email-#{&1}@email.com"),
      refresh_token: "123",
      access_token: "123",
      expires: Timex.now() |> Timex.shift(days: 1)
    }
  end

  def custom_domain_factory do
    %Plausible.Site.CustomDomain{
      domain: sequence(:custom_domain, &"domain-#{&1}.com")
    }
  end

  def tweet_factory do
    %Plausible.Twitter.Tweet{
      tweet_id: UUID.uuid4(),
      author_handle: "author-handle",
      author_name: "author-name",
      author_image: "pic.twitter.com/author.png",
      text: "tweet-text",
      created: Timex.now()
    }
  end

  def weekly_report_factory do
    %Plausible.Site.WeeklyReport{}
  end

  def monthly_report_factory do
    %Plausible.Site.MonthlyReport{}
  end

  def shared_link_factory do
    %Plausible.Site.SharedLink{
      name: "Link name",
      slug: Nanoid.generate()
    }
  end

  def api_key_factory do
    key = :crypto.strong_rand_bytes(64) |> Base.url_encode64() |> binary_part(0, 64)

    %Plausible.Auth.ApiKey{
      name: "api-key-name",
      key: key,
      key_hash: Plausible.Auth.ApiKey.do_hash(key),
      key_prefix: binary_part(key, 0, 6)
    }
  end

  defp hash_key() do
    Keyword.fetch!(
      Application.get_env(:plausible, PlausibleWeb.Endpoint),
      :secret_key_base
    )
    |> binary_part(0, 16)
  end
end
