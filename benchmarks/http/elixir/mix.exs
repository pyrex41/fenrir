defmodule FenrirHttp.MixProject do
  use Mix.Project

  def project do
    [
      app: :fenrir_http_reference,
      version: "0.1.0",
      deps: [{:bandit, "== 1.14.1"}, {:plug, "== 1.20.3"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
