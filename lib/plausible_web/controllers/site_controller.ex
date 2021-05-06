defmodule PlausibleWeb.SiteController do
  use PlausibleWeb, :controller
  use Plausible.Repo
  alias Plausible.{Sites, Goals}

  plug PlausibleWeb.RequireAccountPlug

  def index(conn, params) do
    user = conn.assigns[:current_user]

    {sites, pagination} =
      Repo.paginate(
        from(s in Plausible.Site,
          join: sm in Plausible.Site.Membership,
          on: sm.site_id == s.id,
          where: sm.user_id == ^user.id,
          order_by: s.domain
        ),
        params
      )

    visitors = Plausible.Stats.Clickhouse.last_24h_visitors(sites)
    render(conn, "index.html", sites: sites, visitors: visitors, pagination: pagination)
  end

  def new(conn, _params) do
    current_user = conn.assigns[:current_user]
    site_count = Plausible.Sites.count_for(current_user)
    site_limit = Plausible.Billing.sites_limit(current_user)
    is_at_limit = site_limit && site_count >= site_limit
    is_first_site = site_count == 0

    changeset = Plausible.Site.changeset(%Plausible.Site{})

    render(conn, "new.html",
      changeset: changeset,
      is_first_site: is_first_site,
      is_at_limit: is_at_limit,
      site_limit: site_limit,
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def create_site(conn, %{"site" => site_params}) do
    user = conn.assigns[:current_user]
    site_count = Plausible.Sites.count_for(user)
    is_first_site = site_count == 0

    case Sites.create(user, site_params) do
      {:ok, %{site: site}} ->
        Plausible.Slack.notify("#{user.name} created #{site.domain} [email=#{user.email}]")

        if is_first_site do
          PlausibleWeb.Email.welcome_email(user)
          |> Plausible.Mailer.send_email()
        end

        conn
        |> put_session(site.domain <> "_offer_email_report", true)
        |> redirect(to: "/#{URI.encode_www_form(site.domain)}/snippet")

      {:error, :site, changeset, _} ->
        render(conn, "new.html",
          changeset: changeset,
          is_first_site: is_first_site,
          is_at_limit: false,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )

      {:error, :limit, _limit} ->
        send_resp(conn, 400, "Site limit reached")
    end
  end

  def add_snippet(conn, %{"website" => website}) do
    user = conn.assigns[:current_user]

    site =
      Sites.get_for_user!(conn.assigns[:current_user].id, website)
      |> Repo.preload(:custom_domain)

    is_first_site =
      !Repo.exists?(
        from sm in Plausible.Site.Membership,
          where:
            sm.user_id == ^user.id and
              sm.site_id != ^site.id
      )

    conn
    |> assign(:skip_plausible_tracking, true)
    |> render("snippet.html",
      site: site,
      is_first_site: is_first_site,
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def new_goal(conn, %{"website" => website}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)
    changeset = Plausible.Goal.changeset(%Plausible.Goal{})

    conn
    |> assign(:skip_plausible_tracking, true)
    |> render("new_goal.html",
      site: site,
      changeset: changeset,
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def create_goal(conn, %{"website" => website, "goal" => goal}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    case Plausible.Goals.create(site, goal) do
      {:ok, _} ->
        conn
        |> put_flash(:success, "Goal created successfully")
        |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/goals")

      {:error, changeset} ->
        conn
        |> assign(:skip_plausible_tracking, true)
        |> render("new_goal.html",
          site: site,
          changeset: changeset,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
    end
  end

  def delete_goal(conn, %{"website" => website, "id" => goal_id}) do
    Plausible.Goals.delete(goal_id)

    conn
    |> put_flash(:success, "Goal deleted successfully")
    |> redirect(to: "/#{URI.encode_www_form(website)}/settings/goals")
  end

  def settings(conn, %{"website" => website}) do
    redirect(conn, to: "/#{URI.encode_www_form(website)}/settings/general")
  end

  def settings_general(conn, %{"website" => website}) do
    site =
      Sites.get_for_user!(conn.assigns[:current_user].id, website)
      |> Repo.preload(:custom_domain)

    conn
    |> assign(:skip_plausible_tracking, true)
    |> render("settings_general.html",
      site: site,
      changeset: Plausible.Site.changeset(site, %{}),
      layout: {PlausibleWeb.LayoutView, "site_settings.html"}
    )
  end

  def settings_visibility(conn, %{"website" => website}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)
    shared_links = Repo.all(from l in Plausible.Site.SharedLink, where: l.site_id == ^site.id)

    conn
    |> assign(:skip_plausible_tracking, true)
    |> render("settings_visibility.html",
      site: site,
      shared_links: shared_links,
      layout: {PlausibleWeb.LayoutView, "site_settings.html"}
    )
  end

  def settings_goals(conn, %{"website" => website}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)
    goals = Goals.for_site(site.domain)

    conn
    |> assign(:skip_plausible_tracking, true)
    |> render("settings_goals.html",
      site: site,
      goals: goals,
      layout: {PlausibleWeb.LayoutView, "site_settings.html"}
    )
  end

  def settings_search_console(conn, %{"website" => website}) do
    site =
      Sites.get_for_user!(conn.assigns[:current_user].id, website)
      |> Repo.preload(:google_auth)

    search_console_domains =
      if site.google_auth do
        Plausible.Google.Api.fetch_verified_properties(site.google_auth)
      end

    conn
    |> assign(:skip_plausible_tracking, true)
    |> render("settings_search_console.html",
      site: site,
      search_console_domains: search_console_domains,
      layout: {PlausibleWeb.LayoutView, "site_settings.html"}
    )
  end

  def settings_email_reports(conn, %{"website" => website}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    conn
    |> assign(:skip_plausible_tracking, true)
    |> render("settings_email_reports.html",
      site: site,
      weekly_report: Repo.get_by(Plausible.Site.WeeklyReport, site_id: site.id),
      monthly_report: Repo.get_by(Plausible.Site.MonthlyReport, site_id: site.id),
      spike_notification: Repo.get_by(Plausible.Site.SpikeNotification, site_id: site.id),
      layout: {PlausibleWeb.LayoutView, "site_settings.html"}
    )
  end

  def settings_custom_domain(conn, %{"website" => website}) do
    site =
      Sites.get_for_user!(conn.assigns[:current_user].id, website)
      |> Repo.preload(:custom_domain)

    conn
    |> assign(:skip_plausible_tracking, true)
    |> render("settings_custom_domain.html",
      site: site,
      layout: {PlausibleWeb.LayoutView, "site_settings.html"}
    )
  end

  def settings_danger_zone(conn, %{"website" => website}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    conn
    |> assign(:skip_plausible_tracking, true)
    |> render("settings_danger_zone.html",
      site: site,
      layout: {PlausibleWeb.LayoutView, "site_settings.html"}
    )
  end

  def update_google_auth(conn, %{"website" => website, "google_auth" => attrs}) do
    site =
      Sites.get_for_user!(conn.assigns[:current_user].id, website)
      |> Repo.preload(:google_auth)

    Plausible.Site.GoogleAuth.set_property(site.google_auth, attrs)
    |> Repo.update!()

    conn
    |> put_flash(:success, "Google integration saved successfully")
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/search-console")
  end

  def delete_google_auth(conn, %{"website" => website}) do
    site =
      Sites.get_for_user!(conn.assigns[:current_user].id, website)
      |> Repo.preload(:google_auth)

    Repo.delete!(site.google_auth)

    conn
    |> put_flash(:success, "Google account unlinked from Plausible")
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/search-console")
  end

  def update_settings(conn, %{"website" => website, "site" => site_params}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)
    changeset = site |> Plausible.Site.changeset(site_params)
    res = changeset |> Repo.update()

    case res do
      {:ok, site} ->
        site_session_key = "authorized_site__" <> site.domain

        conn
        |> put_session(site_session_key, nil)
        |> put_flash(:success, "Your site settings have been saved")
        |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/general")

      {:error, changeset} ->
        render(conn, "settings_general.html", site: site, changeset: changeset)
    end
  end

  def reset_stats(conn, %{"website" => website}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)
    Plausible.ClickhouseRepo.clear_stats_for(site.domain)

    conn
    |> put_flash(:success, "#{site.domain} stats will be reset in a few minutes")
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/danger-zone")
  end

  def delete_site(conn, %{"website" => website}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    Repo.delete!(site)
    Plausible.ClickhouseRepo.clear_stats_for(site.domain)

    conn
    |> put_flash(:success, "Site deleted successfully along with all pageviews")
    |> redirect(to: "/sites")
  end

  def make_public(conn, %{"website" => website}) do
    site =
      Sites.get_for_user!(conn.assigns[:current_user].id, website)
      |> Plausible.Site.make_public()
      |> Repo.update!()

    conn
    |> put_flash(:success, "Stats for #{site.domain} are now public.")
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/visibility")
  end

  def make_private(conn, %{"website" => website}) do
    site =
      Sites.get_for_user!(conn.assigns[:current_user].id, website)
      |> Plausible.Site.make_private()
      |> Repo.update!()

    conn
    |> put_flash(:success, "Stats for #{site.domain} are now private.")
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/visibility")
  end

  def enable_weekly_report(conn, %{"website" => website}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    Plausible.Site.WeeklyReport.changeset(%Plausible.Site.WeeklyReport{}, %{
      site_id: site.id,
      recipients: [conn.assigns[:current_user].email]
    })
    |> Repo.insert!()

    conn
    |> put_flash(:success, "You will receive an email report every Monday going forward")
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/email-reports")
  end

  def disable_weekly_report(conn, %{"website" => website}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)
    Repo.delete_all(from wr in Plausible.Site.WeeklyReport, where: wr.site_id == ^site.id)

    conn
    |> put_flash(:success, "You will not receive weekly email reports going forward")
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/email-reports")
  end

  def add_weekly_report_recipient(conn, %{"website" => website, "recipient" => recipient}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    Repo.get_by(Plausible.Site.WeeklyReport, site_id: site.id)
    |> Plausible.Site.WeeklyReport.add_recipient(recipient)
    |> Repo.update!()

    conn
    |> put_flash(:success, "Added #{recipient} as a recipient for the weekly report")
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/email-reports")
  end

  def remove_weekly_report_recipient(conn, %{"website" => website, "recipient" => recipient}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    Repo.get_by(Plausible.Site.WeeklyReport, site_id: site.id)
    |> Plausible.Site.WeeklyReport.remove_recipient(recipient)
    |> Repo.update!()

    conn
    |> put_flash(
      :success,
      "Removed #{recipient} as a recipient for the weekly report"
    )
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/email-reports")
  end

  def enable_monthly_report(conn, %{"website" => website}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    Plausible.Site.MonthlyReport.changeset(%Plausible.Site.MonthlyReport{}, %{
      site_id: site.id,
      recipients: [conn.assigns[:current_user].email]
    })
    |> Repo.insert!()

    conn
    |> put_flash(:success, "You will receive an email report every month going forward")
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/email-reports")
  end

  def disable_monthly_report(conn, %{"website" => website}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)
    Repo.delete_all(from mr in Plausible.Site.MonthlyReport, where: mr.site_id == ^site.id)

    conn
    |> put_flash(:success, "You will not receive monthly email reports going forward")
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/email-reports")
  end

  def add_monthly_report_recipient(conn, %{"website" => website, "recipient" => recipient}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    Repo.get_by(Plausible.Site.MonthlyReport, site_id: site.id)
    |> Plausible.Site.MonthlyReport.add_recipient(recipient)
    |> Repo.update!()

    conn
    |> put_flash(:success, "Added #{recipient} as a recipient for the monthly report")
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/email-reports")
  end

  def remove_monthly_report_recipient(conn, %{"website" => website, "recipient" => recipient}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    Repo.get_by(Plausible.Site.MonthlyReport, site_id: site.id)
    |> Plausible.Site.MonthlyReport.remove_recipient(recipient)
    |> Repo.update!()

    conn
    |> put_flash(
      :success,
      "Removed #{recipient} as a recipient for the monthly report"
    )
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/email-reports")
  end

  def enable_spike_notification(conn, %{"website" => website}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    res =
      Plausible.Site.SpikeNotification.changeset(%Plausible.Site.SpikeNotification{}, %{
        site_id: site.id,
        threshold: 10,
        recipients: [conn.assigns[:current_user].email]
      })
      |> Repo.insert()

    case res do
      {:ok, _} ->
        conn
        |> put_flash(:success, "You will a notification with traffic spikes going forward")
        |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/email-reports")

      {:error, _} ->
        conn
        |> put_flash(:error, "Unable to create a spike notification")
        |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/email-reports")
    end
  end

  def disable_spike_notification(conn, %{"website" => website}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)
    Repo.delete_all(from mr in Plausible.Site.SpikeNotification, where: mr.site_id == ^site.id)

    conn
    |> put_flash(:success, "Spike notification disabled")
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/email-reports")
  end

  def update_spike_notification(conn, %{"website" => website, "spike_notification" => params}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)
    notification = Repo.get_by(Plausible.Site.SpikeNotification, site_id: site.id)

    Plausible.Site.SpikeNotification.changeset(notification, params)
    |> Repo.update!()

    conn
    |> put_flash(:success, "Notification settings updated")
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/email-reports")
  end

  def add_spike_notification_recipient(conn, %{"website" => website, "recipient" => recipient}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    Repo.get_by(Plausible.Site.SpikeNotification, site_id: site.id)
    |> Plausible.Site.SpikeNotification.add_recipient(recipient)
    |> Repo.update!()

    conn
    |> put_flash(:success, "Added #{recipient} as a recipient for the traffic spike notification")
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/email-reports")
  end

  def remove_spike_notification_recipient(conn, %{"website" => website, "recipient" => recipient}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    Repo.get_by(Plausible.Site.SpikeNotification, site_id: site.id)
    |> Plausible.Site.SpikeNotification.remove_recipient(recipient)
    |> Repo.update!()

    conn
    |> put_flash(
      :success,
      "Removed #{recipient} as a recipient for the monthly report"
    )
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/email-reports")
  end

  def new_shared_link(conn, %{"website" => website}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)
    changeset = Plausible.Site.SharedLink.changeset(%Plausible.Site.SharedLink{}, %{})

    conn
    |> assign(:skip_plausible_tracking, true)
    |> render("new_shared_link.html",
      site: site,
      changeset: changeset,
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def create_shared_link(conn, %{"website" => website, "shared_link" => link}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    case Sites.create_shared_link(site, link["name"], link["password"]) do
      {:ok, _created} ->
        redirect(conn, to: "/#{URI.encode_www_form(site.domain)}/settings/visibility")

      {:error, changeset} ->
        conn
        |> assign(:skip_plausible_tracking, true)
        |> render("new_shared_link.html",
          site: site,
          changeset: changeset,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
    end
  end

  def edit_shared_link(conn, %{"website" => website, "slug" => slug}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)
    shared_link = Repo.get_by(Plausible.Site.SharedLink, slug: slug)
    changeset = Plausible.Site.SharedLink.changeset(shared_link, %{})

    conn
    |> assign(:skip_plausible_tracking, true)
    |> render("edit_shared_link.html",
      site: site,
      changeset: changeset,
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def update_shared_link(conn, %{"website" => website, "slug" => slug, "shared_link" => params}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)
    shared_link = Repo.get_by(Plausible.Site.SharedLink, slug: slug)
    changeset = Plausible.Site.SharedLink.changeset(shared_link, params)

    case Repo.update(changeset) do
      {:ok, _created} ->
        redirect(conn, to: "/#{URI.encode_www_form(site.domain)}/settings/visibility")

      {:error, changeset} ->
        conn
        |> assign(:skip_plausible_tracking, true)
        |> render("edit_shared_link.html",
          site: site,
          changeset: changeset,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
    end
  end

  def delete_shared_link(conn, %{"website" => website, "slug" => slug}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    Repo.get_by(Plausible.Site.SharedLink, slug: slug)
    |> Repo.delete!()

    redirect(conn, to: "/#{URI.encode_www_form(site.domain)}/settings/visibility")
  end

  def new_custom_domain(conn, %{"website" => website}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)
    changeset = Plausible.Site.CustomDomain.changeset(%Plausible.Site.CustomDomain{}, %{})

    conn
    |> assign(:skip_plausible_tracking, true)
    |> render("new_custom_domain.html",
      site: site,
      changeset: changeset,
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def custom_domain_dns_setup(conn, %{"website" => website}) do
    site =
      Sites.get_for_user!(conn.assigns[:current_user].id, website)
      |> Repo.preload(:custom_domain)

    conn
    |> assign(:skip_plausible_tracking, true)
    |> render("custom_domain_dns_setup.html",
      site: site,
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def custom_domain_snippet(conn, %{"website" => website}) do
    site =
      Sites.get_for_user!(conn.assigns[:current_user].id, website)
      |> Repo.preload(:custom_domain)

    conn
    |> assign(:skip_plausible_tracking, true)
    |> render("custom_domain_snippet.html",
      site: site,
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def add_custom_domain(conn, %{"website" => website, "custom_domain" => domain}) do
    site = Sites.get_for_user!(conn.assigns[:current_user].id, website)

    case Sites.add_custom_domain(site, domain["domain"]) do
      {:ok, _custom_domain} ->
        redirect(conn, to: "/sites/#{URI.encode_www_form(site.domain)}/custom-domains/dns-setup")

      {:error, changeset} ->
        conn
        |> assign(:skip_plausible_tracking, true)
        |> render("new_custom_domain.html",
          site: site,
          changeset: changeset,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
    end
  end

  def delete_custom_domain(conn, %{"website" => website}) do
    site =
      Sites.get_for_user!(conn.assigns[:current_user].id, website)
      |> Repo.preload(:custom_domain)

    Repo.delete!(site.custom_domain)

    conn
    |> put_flash(:success, "Custom domain deleted successfully")
    |> redirect(to: "/#{URI.encode_www_form(site.domain)}/settings/custom-domain")
  end
end
