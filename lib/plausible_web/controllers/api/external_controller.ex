defmodule PlausibleWeb.Api.ExternalController do
  use PlausibleWeb, :controller
  require Logger

  def event(conn, _params) do
    params = parse_body(conn)
    Sentry.Context.set_extra_context(%{request: params})

    case create_event(conn, params) do
      {:ok, _} ->
        conn |> send_resp(202, "")

      {:error, changeset} ->
        request = Sentry.Plug.build_request_interface_data(conn, [])

        Sentry.capture_message("Error processing event",
          extra: %{errors: inspect(changeset.errors), params: params, request: request}
        )

        Logger.info("Error processing event: #{inspect(changeset)}")
        conn |> send_resp(400, "")
    end
  end

  def error(conn, _params) do
    request = Sentry.Plug.build_request_interface_data(conn, [])
    Sentry.capture_message("JS snippet error", request: request)
    send_resp(conn, 200, "")
  end

  def health(conn, _params) do
    postgres_health =
      case Ecto.Adapters.SQL.query(Plausible.Repo, "SELECT 1", []) do
        {:ok, _} -> "ok"
        e -> "error: #{inspect(e)}"
      end

    clickhouse_health =
      case Ecto.Adapters.SQL.query(Plausible.ClickhouseRepo, "SELECT 1", []) do
        {:ok, _} -> "ok"
        e -> "error: #{inspect(e)}"
      end

    status =
      case {postgres_health, clickhouse_health} do
        {"ok", "ok"} -> 200
        _ -> 500
      end

    put_status(conn, status)
    |> json(%{
      postgres: postgres_health,
      clickhouse: clickhouse_health
    })
  end

  defp parse_user_agent(conn) do
    user_agent = Plug.Conn.get_req_header(conn, "user-agent") |> List.first()

    if user_agent do
      Cachex.fetch!(:user_agents, user_agent, fn ua ->
        {:commit, UAInspector.parse(ua)}
      end)
    end
  end

  defp create_event(conn, params) do
    params = %{
      "name" => params["n"] || params["name"],
      "url" => params["u"] || params["url"],
      "referrer" => params["r"] || params["referrer"],
      "domain" => params["d"] || params["domain"],
      "screen_width" => params["w"] || params["screen_width"],
      "hash_mode" => params["h"] || params["hashMode"],
      "meta" => parse_meta(params)
    }

    ua = parse_user_agent(conn)

    if is_bot?(ua) do
      {:ok, nil}
    else
      uri = params["url"] && URI.parse(params["url"])
      query = if uri && uri.query, do: URI.decode_query(uri.query), else: %{}

      ref = parse_referrer(uri, params["referrer"])
      country_code = visitor_country(conn)
      salts = Plausible.Session.Salts.fetch()

      event_attrs = %{
        timestamp: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
        name: params["name"],
        hostname: strip_www(uri && uri.host),
        domain: strip_www(params["domain"]) || strip_www(uri && uri.host),
        pathname: get_pathname(uri, params["hash_mode"]),
        user_id: generate_user_id(conn, params, salts[:current]),
        referrer_source: get_referrer_source(query, ref) || "",
        referrer: clean_referrer(ref) || "",
        utm_medium: query["utm_medium"] || "",
        utm_source: query["utm_source"] || "",
        utm_campaign: query["utm_campaign"] || "",
        country_code: country_code || "",
        operating_system: (ua && os_name(ua)) || "",
        operating_system_version: (ua && os_version(ua)) || "",
        browser: (ua && browser_name(ua)) || "",
        browser_version: (ua && browser_version(ua)) || "",
        screen_size: calculate_screen_size(params["screen_width"]) || "",
        "meta.key": Map.keys(params["meta"]),
        "meta.value": Map.values(params["meta"]) |> Enum.map(&Kernel.to_string/1)
      }

      changeset = Plausible.ClickhouseEvent.changeset(%Plausible.ClickhouseEvent{}, event_attrs)

      if changeset.valid? do
        previous_user_id = salts[:previous] && generate_user_id(conn, params, salts[:previous])
        event = struct(Plausible.ClickhouseEvent, event_attrs)
        session_id = Plausible.Session.Store.on_event(event, previous_user_id)

        Map.put(event, :session_id, session_id)
        |> Plausible.Event.WriteBuffer.insert()
      else
        {:error, changeset}
      end
    end
  end

  defp is_bot?(%UAInspector.Result.Bot{}), do: true

  defp is_bot?(%UAInspector.Result{client: %UAInspector.Result.Client{name: "Headless Chrome"}}),
    do: true

  defp is_bot?(_), do: false

  defp parse_meta(params) do
    raw_meta = params["m"] || params["meta"] || params["p"] || params["props"]

    if raw_meta do
      Jason.decode!(raw_meta)
    else
      %{}
    end
  end

  defp get_pathname(nil, _), do: "/"

  defp get_pathname(uri, hash_mode) do
    pathname =
      (uri.path || "/")
      |> URI.decode()

    if hash_mode && uri.fragment do
      pathname <> "#" <> URI.decode(uri.fragment)
    else
      pathname
    end
  end

  defp visitor_country(conn) do
    cf_geo = PlausibleWeb.CloudflareGeo.get(conn)

    if cf_geo do
      cf_geo
    else
      Logger.info("No cloudflare geo")
      result =
        PlausibleWeb.RemoteIp.get(conn)
        |> Geolix.lookup()
        |> Map.get(:country)

      if result && result.country do
        result.country.iso_code
      end
    end
  end

  defp parse_referrer(_, nil), do: nil

  defp parse_referrer(uri, referrer_str) do
    referrer_uri = URI.parse(referrer_str)

    if strip_www(referrer_uri.host) !== strip_www(uri.host) && referrer_uri.host !== "localhost" do
      RefInspector.parse(referrer_str)
    end
  end

  defp generate_user_id(conn, params, salt) do
    user_agent = List.first(Plug.Conn.get_req_header(conn, "user-agent")) || ""
    ip_address = PlausibleWeb.RemoteIp.get(conn)
    domain = strip_www(params["domain"]) || ""

    SipHash.hash!(salt, user_agent <> ip_address <> domain)
  end

  defp calculate_screen_size(nil), do: nil
  defp calculate_screen_size(width) when width < 576, do: "Mobile"
  defp calculate_screen_size(width) when width < 992, do: "Tablet"
  defp calculate_screen_size(width) when width < 1440, do: "Laptop"
  defp calculate_screen_size(width) when width >= 1440, do: "Desktop"

  defp clean_referrer(nil), do: nil

  defp clean_referrer(ref) do
    uri = URI.parse(ref.referer)

    if right_uri?(uri) do
      host = String.replace_prefix(uri.host, "www.", "")
      path = uri.path || ""
      host <> String.trim_trailing(path, "/")
    end
  end

  defp parse_body(conn) do
    {:ok, body, _conn} = Plug.Conn.read_body(conn)
    Jason.decode!(body)
  end

  defp strip_www(nil), do: nil

  defp strip_www(hostname) do
    String.replace_prefix(hostname, "www.", "")
  end

  defp browser_name(ua) do
    case ua.client do
      :unknown -> ""
      %UAInspector.Result.Client{name: "Mobile Safari"} -> "Safari"
      %UAInspector.Result.Client{name: "Chrome Mobile"} -> "Chrome"
      %UAInspector.Result.Client{name: "Chrome Mobile iOS"} -> "Chrome"
      %UAInspector.Result.Client{name: "Firefox Mobile"} -> "Firefox"
      %UAInspector.Result.Client{name: "Firefox Mobile iOS"} -> "Firefox"
      %UAInspector.Result.Client{name: "Opera Mobile"} -> "Opera"
      %UAInspector.Result.Client{name: "Chrome Webview"} -> "Mobile App"
      %UAInspector.Result.Client{type: "mobile app"} -> "Mobile App"
      client -> client.name
    end
  end

  defp major_minor(:unknown), do: ""

  defp major_minor(version) do
    version
    |> String.split(".")
    |> Enum.take(2)
    |> Enum.join(".")
  end

  defp browser_version(ua) do
    case ua.client do
      :unknown -> ""
      %UAInspector.Result.Client{type: "mobile app"} -> ""
      client -> major_minor(client.version)
    end
  end

  defp os_name(ua) do
    case ua.os do
      :unknown -> ""
      os -> os.name
    end
  end

  defp os_version(ua) do
    case ua.os do
      :unknown -> ""
      os -> major_minor(os.version)
    end
  end

  defp get_referrer_source(query, ref) do
    source = query["utm_source"] || query["source"] || query["ref"]
    source || get_source_from_referrer(ref)
  end

  defp get_source_from_referrer(nil), do: nil

  defp get_source_from_referrer(ref) do
    case ref.source do
      :unknown ->
        clean_uri(ref.referer)

      source ->
        source
    end
  end

  defp clean_uri(uri) do
    uri = URI.parse(String.trim(uri))

    if right_uri?(uri) do
      String.replace_leading(uri.host, "www.", "")
    end
  end

  defp right_uri?(%URI{host: nil}), do: false

  defp right_uri?(%URI{host: host, scheme: scheme})
       when scheme in ["http", "https"] and byte_size(host) > 0,
       do: true

  defp right_uri?(_), do: false
end
