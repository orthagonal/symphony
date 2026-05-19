defmodule SymphonyElixirWeb.Router do
  @moduledoc """
  Router for Symphony's observability dashboard and API.
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {SymphonyElixirWeb.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/", SymphonyElixirWeb do
    get("/dashboard.css", StaticAssetController, :dashboard_css)
    get("/vendor/phoenix_html/phoenix_html.js", StaticAssetController, :phoenix_html_js)
    get("/vendor/phoenix/phoenix.js", StaticAssetController, :phoenix_js)
    get("/vendor/phoenix_live_view/phoenix_live_view.js", StaticAssetController, :phoenix_live_view_js)
  end

  scope "/", SymphonyElixirWeb do
    pipe_through(:browser)

    post("/tasks", TaskController, :create)
    post("/tasks/:id/delete", TaskController, :delete)
    post("/task-groups/:id/delete", TaskGroupController, :delete)
    post("/tasks/:id/dispatch", TaskController, :dispatch)
    post("/queue/go", QueueController, :go)
    post("/queue/stop", QueueController, :stop)

    get("/codex", LegacyRedirectController, :codex_dashboard)

    live("/", TaskDashboardLive, :index)
    live("/reviews", ReviewsLive, :index)
    live("/reviews/:id", ReviewsLive, :show)
    live("/tasks/new", TaskLive.New, :new)
    live("/tasks/:id", TaskLive.Show, :show)
    live("/task-groups", TaskGroupLive.Index, :index)
    live("/task-groups/:id", TaskGroupLive.Show, :show)
    live("/agents", AgentsLive, :index)
    live("/settings", SettingsLive, :index)
    live("/cursor", DashboardLive, :index)
  end

  scope "/", SymphonyElixirWeb do
    get("/api/v1/state", ObservabilityApiController, :state)
    get("/api/v1/tasks", TasksApiController, :list)
    post("/api/v1/tasks/:id/summarize", TasksApiController, :summarize)
    post("/api/v1/tasks/:id/plan", TasksApiController, :plan)
    post("/api/v1/tasks/:id/status", TasksApiController, :update_status)

    match(:*, "/", ObservabilityApiController, :method_not_allowed)
    match(:*, "/api/v1/state", ObservabilityApiController, :method_not_allowed)
    post("/api/v1/refresh", ObservabilityApiController, :refresh)
    match(:*, "/api/v1/refresh", ObservabilityApiController, :method_not_allowed)
    get("/api/v1/:issue_identifier", ObservabilityApiController, :issue)
    match(:*, "/api/v1/:issue_identifier", ObservabilityApiController, :method_not_allowed)
    match(:*, "/*path", ObservabilityApiController, :not_found)
  end
end
