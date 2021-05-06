defmodule PlausibleWeb.AuthController do
  use PlausibleWeb, :controller
  use Plausible.Repo
  alias Plausible.Auth
  require Logger

  plug PlausibleWeb.RequireLoggedOutPlug
       when action in [:register_form, :register, :login_form, :login]

  plug PlausibleWeb.RequireAccountPlug
       when action in [
              :user_settings,
              :save_settings,
              :delete_me,
              :password_form,
              :set_password,
              :activate_form
            ]

  def register_form(conn, _params) do
    if Keyword.fetch!(Application.get_env(:plausible, :selfhost), :disable_registration) do
      conn
      |> redirect(to: "/login")
    else
      changeset = Plausible.Auth.User.changeset(%Plausible.Auth.User{})

      render(conn, "register_form.html",
        changeset: changeset,
        layout: {PlausibleWeb.LayoutView, "focus.html"}
      )
    end
  end

  def register(conn, params) do
    if Keyword.fetch!(Application.get_env(:plausible, :selfhost), :disable_registration) do
      conn
      |> redirect(to: "/login")
    else
      user = Plausible.Auth.User.new(%Plausible.Auth.User{}, params["user"])

      if PlausibleWeb.Captcha.verify(params["h-captcha-response"]) do
        case Repo.insert(user) do
          {:ok, user} ->
            code = Auth.issue_email_verification(user)
            Logger.info("VERIFICATION CODE: #{code}")
            email_template = PlausibleWeb.Email.activation_email(user, code)
            Plausible.Mailer.send_email(email_template)

            conn
            |> put_session(:current_user_id, user.id)
            |> put_resp_cookie("logged_in", "true",
              http_only: false,
              max_age: 60 * 60 * 24 * 365 * 5000
            )
            |> redirect(to: "/activate")

          {:error, changeset} ->
            render(conn, "register_form.html",
              changeset: changeset,
              layout: {PlausibleWeb.LayoutView, "focus.html"}
            )
        end
      else
        render(conn, "register_form.html",
          changeset: user,
          captcha_error: "Please complete the captcha to register",
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
      end
    end
  end

  def activate_form(conn, _params) do
    user = conn.assigns[:current_user]

    has_code =
      Repo.exists?(
        from c in "email_verification_codes",
          where: c.user_id == ^user.id
      )

    render(conn, "activate.html",
      has_pin: has_code,
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def activate(conn, %{"code" => code}) do
    user = conn.assigns[:current_user]
    {code, ""} = Integer.parse(code)

    case Auth.verify_email(user, code) do
      :ok ->
        redirect(conn, to: "/sites/new")

      {:error, :incorrect} ->
        render(conn, "activate.html",
          error: "Incorrect activation code",
          has_pin: true,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )

      {:error, :expired} ->
        render(conn, "activate.html",
          error: "Code is expired, please request another one",
          has_pin: false,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
    end
  end

  def request_activation_code(conn, _params) do
    user = conn.assigns[:current_user]
    code = Auth.issue_email_verification(user)

    email_template = PlausibleWeb.Email.activation_email(user, code)
    Plausible.Mailer.send_email(email_template)

    conn
    |> put_flash(:success, "Activation code was sent to #{user.email}")
    |> redirect(to: "/activate")
  end

  def password_reset_request_form(conn, _) do
    render(conn, "password_reset_request_form.html",
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def password_reset_request(conn, %{"email" => ""}) do
    render(conn, "password_reset_request_form.html",
      error: "Please enter an email address",
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def password_reset_request(conn, %{"email" => email} = params) do
    if PlausibleWeb.Captcha.verify(params["h-captcha-response"]) do
      user = Repo.get_by(Plausible.Auth.User, email: email)

      if user do
        token = Auth.Token.sign_password_reset(email)
        url = PlausibleWeb.Endpoint.url() <> "/password/reset?token=#{token}"
        Logger.debug("PASSWORD RESET LINK: " <> url)
        email_template = PlausibleWeb.Email.password_reset_email(email, url)
        Plausible.Mailer.deliver_now!(email_template)

        render(conn, "password_reset_request_success.html",
          email: email,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
      else
        render(conn, "password_reset_request_success.html",
          email: email,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
      end
    else
      render(conn, "password_reset_request_form.html",
        error: "Please complete the captcha to reset your password",
        layout: {PlausibleWeb.LayoutView, "focus.html"}
      )
    end
  end

  def password_reset_form(conn, %{"token" => token}) do
    case Auth.Token.verify_password_reset(token) do
      {:ok, _} ->
        render(conn, "password_reset_form.html",
          token: token,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )

      {:error, :expired} ->
        render_error(
          conn,
          401,
          "Your token has expired. Please request another password reset link."
        )

      {:error, _} ->
        render_error(
          conn,
          401,
          "Your token is invalid. Please request another password reset link."
        )
    end
  end

  def password_reset(conn, %{"token" => token, "password" => pw}) do
    case Auth.Token.verify_password_reset(token) do
      {:ok, %{email: email}} ->
        user = Repo.get_by(Auth.User, email: email)
        changeset = Auth.User.set_password(user, pw)

        case Repo.update(changeset) do
          {:ok, _updated} ->
            conn
            |> put_flash(:login_title, "Password updated successfully")
            |> put_flash(:login_instructions, "Please log in with your new credentials")
            |> put_session(:current_user_id, nil)
            |> delete_resp_cookie("logged_in")
            |> redirect(to: "/login")

          {:error, changeset} ->
            render(conn, "password_reset_form.html",
              changeset: changeset,
              token: token,
              layout: {PlausibleWeb.LayoutView, "focus.html"}
            )
        end

      {:error, :expired} ->
        render_error(
          conn,
          401,
          "Your token has expired. Please request another password reset link."
        )

      {:error, _} ->
        render_error(
          conn,
          401,
          "Your token is invalid. Please request another password reset link."
        )
    end
  end

  def login(conn, %{"email" => email, "password" => password}) do
    alias Plausible.Auth.Password

    user =
      Repo.one(
        from u in Plausible.Auth.User,
          where: u.email == ^email
      )

    if user do
      if Password.match?(password, user.password_hash || "") do
        login_dest = get_session(conn, :login_dest) || "/sites"

        conn
        |> put_session(:current_user_id, user.id)
        |> put_resp_cookie("logged_in", "true",
          http_only: false,
          max_age: 60 * 60 * 24 * 365 * 5000
        )
        |> put_session(:login_dest, nil)
        |> redirect(to: login_dest)
      else
        conn
        |> render("login_form.html",
          error: "Wrong email or password. Please try again.",
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
      end
    else
      Password.dummy_calculation()

      conn
      |> render("login_form.html",
        error: "Wrong email or password. Please try again.",
        layout: {PlausibleWeb.LayoutView, "focus.html"}
      )
    end
  end

  def login_form(conn, _params) do
    render(conn, "login_form.html", layout: {PlausibleWeb.LayoutView, "focus.html"})
  end

  def password_form(conn, _params) do
    render(conn, "password_form.html",
      layout: {PlausibleWeb.LayoutView, "focus.html"},
      skip_plausible_tracking: true
    )
  end

  def set_password(conn, %{"password" => pw}) do
    changeset = Auth.User.set_password(conn.assigns[:current_user], pw)

    case Repo.update(changeset) do
      {:ok, _user} ->
        redirect(conn, to: "/sites/new")

      {:error, changeset} ->
        render(conn, "password_form.html",
          changeset: changeset,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
    end
  end

  def user_settings(conn, _params) do
    changeset = Auth.User.changeset(conn.assigns[:current_user])

    {usage_pageviews, usage_custom_events} =
      Plausible.Billing.usage_breakdown(conn.assigns[:current_user])

    render(conn, "user_settings.html",
      user: conn.assigns[:current_user] |> Repo.preload(:api_keys),
      changeset: changeset,
      subscription: conn.assigns[:current_user].subscription,
      theme: conn.assigns[:current_user].theme || "system",
      usage_pageviews: usage_pageviews,
      usage_custom_events: usage_custom_events
    )
  end

  def save_settings(conn, %{"user" => user_params}) do
    changes = Auth.User.changeset(conn.assigns[:current_user], user_params)

    case Repo.update(changes) do
      {:ok, _user} ->
        conn
        |> put_flash(:success, "Account settings saved successfully")
        |> redirect(to: "/settings")

      {:error, changeset} ->
        render(conn, "user_settings.html",
          changeset: changeset,
          subscription: conn.assigns[:current_user].subscription
        )
    end
  end

  def new_api_key(conn, _params) do
    key = :crypto.strong_rand_bytes(64) |> Base.url_encode64() |> binary_part(0, 64)
    changeset = Auth.ApiKey.changeset(%Auth.ApiKey{}, %{key: key})

    render(conn, "new_api_key.html",
      changeset: changeset,
      layout: {PlausibleWeb.LayoutView, "focus.html"}
    )
  end

  def create_api_key(conn, %{"api_key" => key_params}) do
    api_key = %Auth.ApiKey{user_id: conn.assigns[:current_user].id}
    changeset = Auth.ApiKey.changeset(api_key, key_params)

    case Repo.insert(changeset) do
      {:ok, _api_key} ->
        conn
        |> put_flash(:success, "API key created successfully")
        |> redirect(to: "/settings#api-keys")

      {:error, changeset} ->
        render(conn, "new_api_key.html",
          changeset: changeset,
          layout: {PlausibleWeb.LayoutView, "focus.html"}
        )
    end
  end

  def delete_api_key(conn, %{"id" => id}) do
    Repo.get_by(Auth.ApiKey, id: id)
    |> Repo.delete!()

    conn
    |> put_flash(:success, "API key revoked successfully")
    |> redirect(to: "/settings#api-keys")
  end

  def delete_me(conn, params) do
    user =
      conn.assigns[:current_user]
      |> Repo.preload(:sites)
      |> Repo.preload(:subscription)

    for site <- user.sites do
      Repo.delete!(site)
    end

    if user.subscription, do: Repo.delete!(user.subscription)
    Repo.delete!(user)

    logout(conn, params)
  end

  def logout(conn, params) do
    redirect_to = Map.get(params, "redirect", "/")

    conn
    |> configure_session(drop: true)
    |> delete_resp_cookie("logged_in")
    |> redirect(to: redirect_to)
  end

  def google_auth_callback(conn, %{"code" => code, "state" => site_id}) do
    res = Plausible.Google.Api.fetch_access_token(code)
    id_token = res["id_token"]
    [_, body, _] = String.split(id_token, ".")
    id = body |> Base.decode64!(padding: false) |> Jason.decode!()

    Plausible.Site.GoogleAuth.changeset(%Plausible.Site.GoogleAuth{}, %{
      email: id["email"],
      refresh_token: res["refresh_token"],
      access_token: res["access_token"],
      expires: NaiveDateTime.utc_now() |> NaiveDateTime.add(res["expires_in"]),
      user_id: conn.assigns[:current_user].id,
      site_id: site_id
    })
    |> Repo.insert!()

    site = Repo.get(Plausible.Site, site_id)

    redirect(conn, to: "/#{URI.encode_www_form(site.domain)}/settings/search-console")
  end
end
