defmodule SymphonyElixir.TrackerLocalTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Linear.Issue
  alias SymphonyElixir.Tasks
  alias SymphonyElixir.Tracker
  alias SymphonyElixir.Tracker.Local

  setup do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "symphony-local-tracker-#{System.unique_integer([:positive])}.db"
      )

    File.rm(db_path)
    Application.put_env(:symphony_elixir, :tasks_database_path, db_path)
    Tasks.configure_repo!()
    start_supervised!(SymphonyElixir.Repo)
    Ecto.Migrator.run(SymphonyElixir.Repo, :up, all: true)

    write_workflow_file!(
      Workflow.workflow_file_path(),
      tracker_kind: "local",
      tracker_api_token: nil,
      tracker_project_slug: nil,
      tracker_active_states: ["queued", "running"],
      tracker_terminal_states: ["done", "failed", "cancelled"]
    )

    on_exit(fn -> File.rm(db_path) end)

    :ok
  end

  test "local adapter reads and updates sqlite tasks as issues" do
    assert Tracker.adapter() == Local

    {:ok, queued} = Tasks.create(%{title: "Queued task", body: "details", priority: 2})
    {:ok, running} = Tasks.create(%{title: "Running task", status: "running"})
    {:ok, _done} = Tasks.create(%{title: "Done task", status: "done"})

    assert {:ok, issues} = Tracker.fetch_candidate_issues()
    ids = Enum.map(issues, & &1.id) |> MapSet.new()
    assert MapSet.member?(ids, Integer.to_string(queued.id))
    assert MapSet.member?(ids, Integer.to_string(running.id))
    refute MapSet.member?(ids, Integer.to_string(_done.id))

    assert {:ok, running_issues} = Tracker.fetch_issues_by_states(["running"])
    assert [%Issue{id: running_id, state: "running"}] = running_issues
    assert running_id == Integer.to_string(running.id)

    assert {:ok, [refreshed]} = Tracker.fetch_issue_states_by_ids([Integer.to_string(queued.id)])
    assert refreshed.id == Integer.to_string(queued.id)

    assert :ok = Tracker.create_comment(Integer.to_string(queued.id), "progress update")
    assert :ok = Tracker.update_issue_state(Integer.to_string(queued.id), "running")

    assert %Tasks.Task{status: "running"} = Tasks.get!(queued.id)
    assert [_comment] = SymphonyElixir.Repo.all(SymphonyElixir.Tasks.TaskEvent)
  end
end
