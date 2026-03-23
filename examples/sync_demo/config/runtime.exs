import Config

if config_env() == :prod do
  host = System.get_env("PHX_HOST", "localhost")
  secret = System.get_env("SECRET_KEY_BASE")
  check_origin = System.get_env("PHX_CHECK_ORIGIN", "true") != "false"

  config :sync_demo, SyncDemoWeb.Endpoint,
    url: [host: host, scheme: "https", port: 443],
    secret_key_base: secret || SyncDemoWeb.Endpoint.config(:secret_key_base),
    check_origin: check_origin
end
