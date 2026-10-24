# Demo data for the Resources guide screenshots.
#
# Creates a small, believable workspace to photograph: one demo owner with two
# teammates (all @example.test), an AI-optimized board and a custom board, tasks
# in every column, a goal with children, a task waiting in Review, labels, a
# comment with a mention, an API token record, and four weeks of completed work
# so the metrics charts have data, with the workflow steps each agent reported
# so the Compliance page has data too. See
# priv/static/images/resources/guides/README.md for how to use it.
#
# Run it inside the running dev app with Tidewave project_eval, never with mix
# in a shell while the dev server is up:
#
#     {summary, _binding} = Code.eval_file("priv/repo/resources_demo_seeds.exs")
#     summary
#
# Return only the summary: the binding holds every top-level value the script
# built.
#
# It is idempotent. Users and memberships are found or created; a board that
# already exists is left as it is, so delete a demo board in the UI and run the
# seed again to rebuild it. The one exception is the reviewed agent task "Add a
# delivery estimate to the order summary", which is added to an existing
# Checkout Revamp board when it is missing.
#
# Optional environment variables:
#
#   * RESOURCES_DEMO_PASSWORD - the password for the demo users (12+ characters).
#     Without it each user gets a random password that is never printed.
#   * RESOURCES_DEMO_VIEWER - the email of an existing dev user to add to both
#     demo boards with modify access, so you can photograph them from a browser
#     that is already signed in.
#
# It refuses to run anywhere but the dev database (and the test database, so
# its own test can run it), and it never creates an Organization.

import Ecto.Query

alias Kanban.Accounts
alias Kanban.Accounts.Scope
alias Kanban.Accounts.User
alias Kanban.ApiTokens
alias Kanban.Boards
alias Kanban.Boards.Board
alias Kanban.Boards.BoardUser
alias Kanban.Columns
alias Kanban.Labels
alias Kanban.Repo
alias Kanban.Tasks
alias Kanban.Tasks.Mentions
alias Kanban.Tasks.Task

# --- Guard -------------------------------------------------------------------

# A caller may pass `env:` or `database:` in the binding (the test does), but
# only to make the guard stricter: the real environment must pass too.
seed_overrides = binding()

real_env = if Code.ensure_loaded?(Mix), do: Mix.env(), else: :prod
database = to_string(Repo.config()[:database])

allowed? = fn env, db ->
  env in [:dev, :test] and Regex.match?(~r/\Akanban_(dev|test\d*)\z/, db)
end

unless allowed?.(real_env, database) and
         allowed?.(
           Keyword.get(seed_overrides, :env, real_env),
           Keyword.get(seed_overrides, :database, database)
         ) do
  raise "resources_demo_seeds.exs only runs against the dev database, not #{inspect(database)}"
end

# --- Settings ----------------------------------------------------------------

# The password is only ever read inside these functions. Code.eval_file/1
# returns every top-level variable in its binding, and Tidewave prints that
# binding, so a top-level password would be shown to whoever ran the seed.
chosen_password = fn ->
  case System.get_env("RESOURCES_DEMO_PASSWORD") do
    nil -> nil
    "" -> nil
    value when byte_size(value) in 12..72 -> value
    _ -> raise "RESOURCES_DEMO_PASSWORD must be 12 to 72 characters"
  end
end

# Fail before anything is written when the password is unusable.
_ = chosen_password.()

new_password = fn ->
  chosen_password.() || Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
end

now = DateTime.utc_now() |> DateTime.truncate(:second)
ago = fn hours -> DateTime.add(now, -hours * 3600, :second) end
naive_ago = fn hours -> hours |> ago.() |> DateTime.to_naive() end

agents = ["Claude Opus 5.5", "Claude Sonnet 5.5", "Codex", "Claude Haiku 4.5"]

# The workflow steps an agent reported when it completed finished task i, so
# the Compliance page has dispatch rates, skip reasons and per-agent numbers.
# Deterministic, and it uses no outer variables. rem(i, 4) is the agent's
# index in `agents`: Codex never runs a planner or reviewer, and some Haiku
# tasks report no steps at all.
demo_workflow_steps = fn i ->
  dispatched = fn name, ms -> %{"name" => name, "dispatched" => true, "duration_ms" => ms} end

  skipped = fn name, code, reason ->
    %{"name" => name, "dispatched" => false, "reason" => reason, "reason_code" => code}
  end

  explorer =
    if rem(i, 6) == 5,
      do: skipped.("explorer", "ran_inline", "Explored inline: the change touched one module."),
      else: dispatched.("explorer", 40_000 + rem(i * 17, 9) * 5_000)

  planner =
    cond do
      rem(i, 9) in [0, 1, 2, 4, 6] ->
        dispatched.("planner", 30_000 + rem(i * 11, 7) * 4_000)

      rem(i, 9) == 8 ->
        skipped.(
          "planner",
          "subsumed_by_task_spec",
          "The task spec already names the files and the approach."
        )

      rem(i, 9) == 7 ->
        skipped.("planner", "folded_into_prior_step", "The explorer returned a complete plan.")

      true ->
        skipped.(
          "planner",
          "decision_matrix_skip",
          "Small, low-risk task: the decision matrix skips the planner."
        )
    end

  implementation =
    if rem(i, 11) == 10,
      do: skipped.("implementation", "ran_inline", "Implemented inline: a one-line fix."),
      else: dispatched.("implementation", 300_000 + rem(i * 37, 13) * 60_000)

  reviewer =
    cond do
      rem(i, 5) in [0, 2] ->
        dispatched.("reviewer", 45_000 + rem(i * 13, 8) * 6_000)

      rem(i, 20) == 19 ->
        skipped.(
          "reviewer",
          "matrix_deviation",
          "The matrix called for a review; skipped to ship the hotfix."
        )

      true ->
        skipped.(
          "reviewer",
          "decision_matrix_skip",
          "Small task: the decision matrix skips the reviewer."
        )
    end

  after_doing =
    if rem(i, 8) == 6,
      do:
        skipped.(
          "after_doing",
          "hook_body_empty",
          "The after_doing section of .stride.md is empty."
        ),
      else: dispatched.("after_doing", 20_000 + rem(i * 7, 10) * 3_000)

  before_review =
    if rem(i, 3) == 1,
      do:
        skipped.(
          "before_review",
          "hook_body_empty",
          "The before_review section of .stride.md is empty."
        ),
      else: dispatched.("before_review", 15_000 + rem(i * 3, 10) * 2_000)

  cond do
    rem(i, 4) == 3 and rem(i, 8) == 7 -> []
    rem(i, 4) == 2 -> [explorer, implementation, after_doing, before_review]
    true -> [explorer, planner, implementation, reviewer, after_doing, before_review]
  end
end

# --- Helpers -----------------------------------------------------------------

find_or_create_user = fn email, name ->
  user =
    case Accounts.get_user_by_email(email) do
      nil ->
        {:ok, user} =
          Accounts.register_user(%{email: email, name: name, password: new_password.()})

        user

      user ->
        # A password given on a later run replaces the old one. The password
        # changeset keeps the user's sessions, unlike Accounts.update_user_password/2.
        if password = chosen_password.() do
          {:ok, _} = user |> User.password_changeset(%{password: password}) |> Repo.update()
        end

        user
    end

  # Confirm the account and dismiss the two-factor reminder banner, which would
  # otherwise sit across the top of every screenshot.
  from(u in User, where: u.id == ^user.id)
  |> Repo.update_all(
    set: [confirmed_at: user.confirmed_at || now, two_factor_reminder_dismissed_at: now]
  )

  Repo.get!(User, user.id)
end

owned_board = fn owner, name ->
  Repo.one(
    from b in Board,
      join: bu in BoardUser,
      on: bu.board_id == b.id,
      where: bu.user_id == ^owner.id and bu.access == :owner and b.name == ^name,
      limit: 1
  )
end

ensure_member = fn board, user, owner ->
  member? =
    Repo.exists?(from bu in BoardUser, where: bu.board_id == ^board.id and bu.user_id == ^user.id)

  if member? do
    :member
  else
    case Boards.add_user_to_board(board, user, :modify, owner) do
      {:ok, _} ->
        :member

      # Free boards cap members at three when plans are enforced.
      {:error, :member_cap_reached} ->
        IO.puts("Skipped adding #{user.name} to #{board.name}: the board's member cap is reached")
        :skipped

      # A disabled account, for example. Raising inside a board's transaction
      # rolls the whole board back.
      {:error, reason} ->
        raise "Couldn't add #{user.name} to #{board.name}: #{inspect(reason)}"
    end
  end
end

columns_by_name = fn board ->
  board |> Columns.list_columns() |> Map.new(&{&1.name, &1})
end

backdate = fn task, inserted_hours_ago ->
  from(t in Task, where: t.id == ^task.id)
  |> Repo.update_all(set: [inserted_at: naive_ago.(inserted_hours_ago)])
end

add_task = fn column, attrs, label_ids, owner ->
  {inserted_hours_ago, attrs} = Map.pop(attrs, :inserted_hours_ago)
  {:ok, task} = Tasks.create_task(column, attrs)
  if inserted_hours_ago, do: backdate.(task, inserted_hours_ago)

  if label_ids != [] do
    {:ok, _} = Labels.set_task_labels(Scope.for_user(owner), task, label_ids)
  end

  task
end

# --- Users ---------------------------------------------------------------------

maya = find_or_create_user.("maya.chen@example.test", "Maya Chen")
priya = find_or_create_user.("priya.raman@example.test", "Priya Raman")
marcus = find_or_create_user.("marcus.bell@example.test", "Marcus Bell")
# On no board, so a "search for users" screenshot has someone to find.
_jordan = find_or_create_user.("jordan.alvarez@example.test", "Jordan Alvarez")

viewer =
  case System.get_env("RESOURCES_DEMO_VIEWER") do
    email when is_binary(email) and email != "" ->
      Accounts.get_user_by_email(email) ||
        raise "RESOURCES_DEMO_VIEWER #{inspect(email)} is not a user in this database"

    _ ->
      nil
  end

# --- AI-optimized board: Checkout Revamp -----------------------------------------

seed_ai_board = fn ->
  {:ok, board} =
    Boards.create_ai_optimized_board(maya, %{
      name: "Checkout Revamp",
      description: "A faster, safer checkout for the web store and the mobile apps"
    })

  Enum.each([priya, marcus], &ensure_member.(board, &1, maya))
  columns = columns_by_name.(board)
  scope = Scope.for_user(maya)

  labels =
    Map.new(
      [
        {"Payments", :green},
        {"iOS", :blue},
        {"Android", :teal},
        {"Accessibility", :purple},
        {"Performance", :orange}
      ],
      fn {name, color} ->
        {:ok, label} = Labels.create_label(scope, board, %{name: name, color: color})
        {name, label.id}
      end
    )

  label_ids = fn names -> Enum.map(names, &Map.fetch!(labels, &1)) end

  open_tasks = [
    {"Backlog", "Support Apple Pay on the web checkout", :work, :medium, ["Payments"], 300},
    {"Backlog", "Remember the shopper's last shipping method", :work, :low, [], 280},
    {"Backlog", "Promo code field loses focus on Android", :defect, :high, ["Android"], 90},
    {"Ready", "Show a clear message when a card is declined", :work, :high, ["Payments"], 200},
    {"Ready", "Prefetch shipping rates while the cart loads", :work, :medium, ["Performance"],
     160},
    {"Ready", "Add VoiceOver labels to the payment sheet", :work, :medium,
     ["Accessibility", "iOS"], 140}
  ]

  for {column, title, type, priority, names, inserted} <- open_tasks do
    add_task.(
      columns[column],
      %{
        title: title,
        type: type,
        priority: priority,
        complexity: :medium,
        description: "#{title}.",
        inserted_hours_ago: inserted
      },
      label_ids.(names),
      maya
    )
  end

  doing = [
    {"Retry failed card payments before showing an error", :work, :high, ["Payments"], marcus, 5},
    {"Order total rounds wrong for some currencies", :defect, :critical, ["Payments"], priya, 2}
  ]

  for {title, type, priority, names, assignee, claimed} <- doing do
    add_task.(
      columns["Doing"],
      %{
        title: title,
        type: type,
        priority: priority,
        complexity: :medium,
        status: :in_progress,
        claimed_at: ago.(claimed),
        assigned_to_id: assignee.id,
        inserted_hours_ago: claimed + 70
      },
      label_ids.(names),
      maya
    )
  end

  # The Review task carries what an agent's completion would: acceptance
  # criteria, a structured review and a diff for each changed file, so the
  # Review queue shows a full task rather than empty panels.
  review_criteria = [
    "The order summary is visible without scrolling on a 375px-wide phone",
    "The Pay button stays on screen while the summary is open",
    "The summary total matches the cart total"
  ]

  review_diffs = [
    %{
      "path" => "lib/storefront_web/components/order_summary.ex",
      "diff" => """
      --- a/lib/storefront_web/components/order_summary.ex
      +++ b/lib/storefront_web/components/order_summary.ex
      @@ -14,8 +14,9 @@ defmodule StorefrontWeb.Components.OrderSummary do
         def order_summary(assigns) do
           ~H\"\"\"
      -    <section class="order-summary">
      +    <section class="order-summary order-summary--sticky" aria-label="Order summary">
             <.line_items items={@cart.items} />
      -      <.totals cart={@cart} />
      +      <.totals cart={@cart} compact={@compact} />
      +      <p :if={@compact} class="order-summary__total">{@cart.total}</p>
           </section>
           \"\"\"
         end
      """
    },
    %{
      "path" => "assets/css/checkout.css",
      "diff" => """
      --- a/assets/css/checkout.css
      +++ b/assets/css/checkout.css
      @@ -41,3 +41,12 @@
       .order-summary {
         padding: 1rem;
       }
      +
      +.order-summary--sticky {
      +  position: sticky;
      +  top: 0;
      +}
      +
      +@media (max-width: 360px) {
      +  .order-summary .line-items { display: none; }
      +}
      """
    },
    %{
      "path" => "test/storefront_web/components/order_summary_test.exs",
      "diff" => """
      --- a/test/storefront_web/components/order_summary_test.exs
      +++ b/test/storefront_web/components/order_summary_test.exs
      @@ -22,3 +22,9 @@ defmodule StorefrontWeb.Components.OrderSummaryTest do
           assert html =~ "Order summary"
         end
      +
      +  test "the summary renders before the payment form" do
      +    html = render_component(&checkout/1, cart: cart_fixture())
      +    [summary_at, payment_at] = Enum.map(["order-summary", "payment-form"], &position(html, &1))
      +    assert summary_at < payment_at
      +  end
       end
      """
    }
  ]

  review_task =
    add_task.(
      columns["Review"],
      %{
        title: "Move the order summary above the fold",
        type: :work,
        priority: :medium,
        complexity: :small,
        status: :in_progress,
        needs_review: true,
        review_status: :pending,
        claimed_at: ago.(30),
        completed_at: ago.(3),
        completed_by_agent: "Claude Opus 5.5",
        workflow_steps: demo_workflow_steps.(0),
        completion_summary:
          "Moved the order summary into the first screen on phones and kept the Pay button in view.",
        completion_notes:
          "Checked on an iPhone SE and a Pixel 7 simulator. Below 360px the summary collapses to one line with the total.",
        completed_by_id: priya.id,
        acceptance_criteria: Enum.join(review_criteria, "\n"),
        testing_strategy: %{
          "unit_tests" => ["The summary renders before the payment form"],
          "manual_tests" => ["Check the checkout on an iPhone SE"]
        },
        patterns_to_follow:
          "Follow the existing checkout components in lib/storefront_web/components",
        pitfalls: ["Don't hide the Pay button behind the summary"],
        security_considerations: ["Show no more than the last four card digits in the summary"],
        actual_files_changed: Enum.map_join(review_diffs, ", ", & &1["path"]),
        changed_files: review_diffs,
        reviewer_result: %{
          "dispatched" => true,
          "schema_version" => "1.0",
          "status" => "approved",
          "summary" =>
            "All three acceptance criteria are met: the summary renders above the fold at 375px and the Pay button stays visible.",
          "duration_ms" => 48_000,
          "acceptance_criteria_checked" => length(review_criteria),
          "issues_found" => 0,
          "issues" => [],
          "acceptance_criteria" =>
            Enum.map(review_criteria, fn criterion ->
              %{
                "criterion" => criterion,
                "status" => "met",
                "evidence" => "test/storefront_web/components/order_summary_test.exs"
              }
            end),
          "project_checks" => [],
          "testing_strategy" => %{"status" => "passed"},
          "patterns" => %{"status" => "passed"},
          "pitfalls" => %{"status" => "passed"},
          "security_considerations" => %{"status" => "passed"}
        },
        assigned_to_id: priya.id,
        inserted_hours_ago: 120
      },
      label_ids.(["Performance", "iOS"]),
      maya
    )

  from(t in Task, where: t.id == ^review_task.id)
  |> Repo.update_all(set: [review_requested_at: ago.(3)])

  {:ok, _comment} =
    Tasks.create_comment(Scope.for_user(priya), review_task, %{
      "content" =>
        "@[#{Mentions.token_name(maya.name)}](user:#{maya.id}) the summary now stays visible on small phones. Can you check it on an iPhone SE before we ship?"
    })

  {:ok, %{goal: goal, child_tasks: [stored, shown, removed]}} =
    Tasks.create_goal_with_tasks(
      columns["Ready"],
      %{
        title: "Saved payment methods",
        description: "Let returning shoppers pay with a card they saved before.",
        priority: :high,
        complexity: :large
      },
      [
        %{title: "Store card tokens with the payment provider", type: :work, priority: :high},
        %{title: "Show saved cards in the payment sheet", type: :work, priority: :high},
        %{title: "Let shoppers remove a saved card", type: :work, priority: :medium}
      ]
    )

  {:ok, stored} = Tasks.move_task(stored, columns["Done"], 0)

  {:ok, _} =
    Tasks.update_task(stored, %{
      status: :completed,
      claimed_at: ago.(60),
      completed_at: ago.(26),
      completed_by_agent: "Claude Sonnet 5.5"
    })

  # Created days before any of it was claimed, so no lead or backlog wait is
  # negative.
  backdate.(goal, 120)
  backdate.(stored, 100)
  backdate.(shown, 50)
  backdate.(removed, 50)

  # Set the dependency once its prerequisite is done: a dependency change
  # recomputes the blocked status, which would reset an in-progress task.
  {:ok, shown} =
    Tasks.update_task(shown, %{
      dependencies: [stored.identifier],
      description: "Let returning shoppers pick a saved card in the payment sheet.",
      acceptance_criteria:
        "Saved cards appear above the new-card form\nEach card shows its brand, last four digits and expiry"
    })

  {:ok, shown} = Tasks.move_task(shown, columns["Doing"], 2)

  {:ok, _} =
    Tasks.update_task(shown, %{
      status: :in_progress,
      claimed_at: ago.(4),
      assigned_to_id: marcus.id
    })

  _ = removed

  done = [
    {"Add a progress indicator to the checkout steps", :work, ["Performance"]},
    {"Validate postcodes as the shopper types", :work, []},
    {"Cache tax rates for each region", :work, ["Performance"]},
    {"Double charge on slow networks", :defect, ["Payments"]},
    {"Format currency in receipts for each locale", :work, []},
    {"Send the receipt email within a minute", :work, []},
    {"Lazy-load product images in the cart", :work, ["Performance"]},
    {"Show delivery estimates on the review step", :work, []},
    {"Keep the cart after the shopper signs in", :work, []},
    {"Hide the coupon field until it is needed", :work, []},
    {"Log payment provider latency", :work, ["Payments"]},
    {"Pay button stays disabled after an error", :defect, ["Payments"]},
    {"Add Google Pay on Android", :work, ["Payments", "Android"]},
    {"Trim unused JavaScript from checkout", :work, ["Performance"]},
    {"Fill the billing address from shipping", :work, []},
    {"Announce the order confirmation to screen readers", :work, ["Accessibility"]},
    {"Keyboard covers the postcode field on iOS", :defect, ["iOS"]},
    {"Report checkout drop-off by step", :work, []},
    {"Retry receipt emails that bounce", :work, []},
    {"Show the card brand as the shopper types", :work, ["Payments"]},
    {"Speed up the order history page", :work, ["Performance"]},
    {"Add alt text to the payment provider logos", :work, ["Accessibility"]},
    {"Cut the checkout page weight in half", :work, ["Performance"]},
    {"Show the estimated tax before payment", :work, []},
    {"Wrong currency symbol for Swiss francs", :defect, ["Payments"]},
    {"Add a guest checkout option", :work, []},
    {"Let shoppers edit the cart from the review step", :work, []},
    {"Address autocomplete fails on Firefox", :defect, []},
    {"Support 3-D Secure card challenges", :work, ["Payments"]},
    {"Remember the shopper's preferred payment method", :work, ["Payments"]},
    {"Show progress while the payment confirms", :work, []},
    {"Keep error messages readable at 200% zoom", :work, ["Accessibility"]},
    {"Rate-limit the payment endpoint", :work, ["Payments"]},
    {"Duplicate orders on a double click", :defect, ["Payments"]},
    {"Track payment failures by provider", :work, ["Payments"]},
    {"Translate checkout into French and German", :work, []}
  ]

  # Days ago each task in `done` was finished: an uneven spread over four weeks,
  # with quiet weekends, so the throughput chart looks like real work.
  done_days = [
    0,
    0,
    1,
    1,
    1,
    2,
    3,
    3,
    6,
    7,
    7,
    7,
    8,
    9,
    9,
    10,
    13,
    14,
    14,
    15,
    15,
    15,
    16,
    17,
    20,
    21,
    21,
    22,
    22,
    23,
    24,
    24,
    24,
    27,
    28,
    28
  ]

  done
  |> Enum.with_index()
  |> Enum.each(fn {{title, type, names}, i} ->
    # Spread completions across the last four weeks with varied cycle, backlog
    # and review times, so every metrics chart has a shape.
    completed = Enum.at(done_days, i) * 24 + 2 + rem(i * 5, 9)
    claimed = completed + 2 + rem(i * 7, 30)
    inserted = claimed + 24 * (1 + rem(i * 3, 6))
    reviewed? = rem(i, 2) == 0

    review_attrs =
      if reviewed? do
        %{
          needs_review: true,
          review_status: :approved,
          reviewed_at: ago.(completed - 1 - rem(i, 8)),
          reviewed_by_id: maya.id
        }
      else
        %{}
      end

    add_task.(
      columns["Done"],
      Map.merge(
        %{
          title: title,
          type: type,
          priority: Enum.at([:medium, :high, :low, :medium], rem(i, 4)),
          complexity: Enum.at([:small, :medium, :small, :large], rem(i, 4)),
          status: :completed,
          claimed_at: ago.(claimed),
          completed_at: ago.(completed),
          completed_by_agent: Enum.at(agents, rem(i, length(agents))),
          workflow_steps: demo_workflow_steps.(i),
          inserted_hours_ago: inserted
        },
        review_attrs
      ),
      label_ids.(names),
      maya
    )
  end)

  # The record a guide's API-token screenshot needs. The plaintext token is
  # dropped here and never printed or stored.
  {:ok, {_token, _plaintext}} =
    ApiTokens.create_api_token(maya, board, %{"name" => "Checkout agent"})

  board
end

# --- Custom board: Marketing Site Launch -------------------------------------------

seed_custom_board = fn ->
  {:ok, board} =
    Boards.create_board(maya, %{
      name: "Marketing Site Launch",
      description: "Pages, copy and assets for the new marketing site"
    })

  Enum.each([priya, marcus], &ensure_member.(board, &1, maya))

  columns =
    Map.new(
      [{"To Do", 0}, {"In Progress", 3}, {"In Review", 0}, {"Published", 0}],
      fn {name, wip} ->
        {:ok, column} = Columns.create_column(board, %{name: name, wip_limit: wip}, maya)
        {name, column}
      end
    )

  tasks = [
    {"To Do", "Write the pricing page copy", :high, nil},
    {"To Do", "Choose the hero photography", :medium, nil},
    {"To Do", "Draft the launch announcement", :medium, nil},
    {"In Progress", "Build the newsletter signup form", :high, priya},
    {"In Progress", "Set up analytics events for the signup funnel", :medium, marcus},
    {"In Progress", "Compress the homepage hero video", :low, priya},
    {"In Review", "Add the customer quotes section", :medium, priya},
    {"Published", "Publish the press kit", :low, marcus},
    {"Published", "Redirect the old blog URLs", :medium, priya}
  ]

  for {column, title, priority, assignee} <- tasks do
    add_task.(
      columns[column],
      %{
        title: title,
        type: :work,
        priority: priority,
        assigned_to_id: assignee && assignee.id,
        inserted_hours_ago: 96
      },
      [],
      maya
    )
  end

  board
end

# --- Run -------------------------------------------------------------------------

created =
  for {name, seed} <- [
        {"Checkout Revamp", seed_ai_board},
        {"Marketing Site Launch", seed_custom_board}
      ],
      is_nil(owned_board.(maya, name)) do
    # One transaction per board, so a run that fails part-way leaves no
    # half-built board for the next run to skip.
    {:ok, _board} = Repo.transaction(fn -> seed.() end)
    name
  end

# --- A reviewed agent task, added even to an existing board ----------------------

# A finished, approved agent task with every section the task view can show:
# context, key files, a behaviour/test matrix, observability, an explorer
# result, a review, actuals and a diff, for the "reading a task's details"
# guide. It is found or created by title, so it also reaches a Checkout Revamp
# board seeded before it existed (rebuilding that board would orphan the demo
# delivery target, which can't be deleted).
reviewed_title = "Add a delivery estimate to the order summary"

reviewed_criteria = [
  "The order summary shows the delivery estimate for the chosen shipping method",
  "The estimate updates when the shopper changes the shipping method",
  "Without an estimate from the carrier, the summary shows no date rather than a guess"
]

reviewed_diffs = [
  %{
    "path" => "lib/storefront/shipping/estimate.ex",
    "diff" => """
    --- a/lib/storefront/shipping/estimate.ex
    +++ b/lib/storefront/shipping/estimate.ex
    @@ -8,6 +8,17 @@ defmodule Storefront.Shipping.Estimate do
       alias Storefront.Shipping.Carrier

    +  @doc "The delivery window for `method`, or nil when the carrier gives none."
    +  def for_method(%{carrier: carrier, service: service}, postcode) do
    +    case Carrier.quote(carrier, service, postcode) do
    +      {:ok, %{earliest: earliest, latest: latest}} -> {earliest, latest}
    +      _ -> nil
    +    end
    +  end
    +
       def business_days(from, days) do
    """
  },
  %{
    "path" => "lib/storefront_web/components/order_summary.ex",
    "diff" => """
    --- a/lib/storefront_web/components/order_summary.ex
    +++ b/lib/storefront_web/components/order_summary.ex
    @@ -21,6 +21,9 @@ defmodule StorefrontWeb.Components.OrderSummary do
             <.line_items items={@cart.items} />
             <.totals cart={@cart} compact={@compact} />
    +        <p :if={@estimate} class="order-summary__delivery">
    +          Arrives {format_window(@estimate)}
    +        </p>
           </section>
    """
  },
  %{
    "path" => "test/storefront/shipping/estimate_test.exs",
    "diff" => """
    --- a/test/storefront/shipping/estimate_test.exs
    +++ b/test/storefront/shipping/estimate_test.exs
    @@ -30,3 +30,15 @@ defmodule Storefront.Shipping.EstimateTest do
         assert Estimate.business_days(~D[2026-10-23], 2) == ~D[2026-10-27]
       end
    +
    +  test "for_method/2 returns the carrier's window" do
    +    stub_carrier({:ok, %{earliest: ~D[2026-10-27], latest: ~D[2026-10-29]}})
    +    assert Estimate.for_method(standard(), "M5V 2T6") == {~D[2026-10-27], ~D[2026-10-29]}
    +  end
    +
    +  test "for_method/2 returns nil when the carrier gives no window" do
    +    stub_carrier({:error, :no_quote})
    +    assert Estimate.for_method(standard(), "M5V 2T6") == nil
    +  end
     end
    """
  }
]

reviewed_matrix =
  [
    {"Happy path", "Shows the carrier's window for the chosen method",
     "test/storefront/shipping/estimate_test.exs — \"for_method/2 returns the carrier's window\"",
     "unit"},
    {"Boundary", "A window that ends on a weekend skips to the next business day",
     "test/storefront/shipping/estimate_test.exs — \"business_days/2 skips weekends\"", "unit"},
    {"Error / exception", "No date is shown when the carrier returns an error",
     "test/storefront/shipping/estimate_test.exs — \"for_method/2 returns nil when the carrier gives no window\"",
     "unit"},
    {"Null / empty", "A cart with no shipping method shows no estimate",
     "test/storefront_web/components/order_summary_test.exs — \"no estimate without a method\"",
     "unit"},
    {"Concurrency", nil, nil, nil},
    {"Lifecycle / wiring", "Changing the shipping method refreshes the estimate",
     "test/storefront_web/live/checkout_live_test.exs — \"estimate follows the shipping method\"",
     "integration"},
    {"Contract / serialization", "The carrier quote's dates parse as ISO 8601",
     "test/storefront/shipping/carrier_test.exs — \"quote dates are ISO 8601\"", "unit"}
  ]
  |> Enum.with_index()
  |> Enum.map(fn
    {{"Concurrency" = category, nil, nil, nil}, i} ->
      %{
        category: category,
        behaviour: "N/A: the estimate is read-only and per request",
        test_name: "N/A",
        status: "not_applicable",
        na_reason: "Nothing is written, so there is no shared state to race",
        position: i
      }

    {{category, behaviour, test_name, type}, i} ->
      %{
        category: category,
        behaviour: behaviour,
        test_name: test_name,
        type: type,
        status: "passing",
        position: i
      }
  end)

ensure_reviewed_task = fn board ->
  existing =
    Repo.exists?(
      from t in Task,
        join: c in assoc(t, :column),
        where: c.board_id == ^board.id and t.title == ^reviewed_title
    )

  if existing do
    :exists
  else
    columns = columns_by_name.(board)

    add_task.(
      columns["Done"],
      %{
        title: reviewed_title,
        type: :work,
        priority: :medium,
        complexity: :medium,
        estimated_files: "3-5",
        status: :completed,
        description:
          "Shoppers abandon checkout when they can't tell when an order will arrive. Show the carrier's delivery window in the order summary.",
        why: "Shoppers leave checkout when they can't see when their order will arrive.",
        what: "A delivery window from the carrier, shown in the order summary.",
        where_context: "Checkout: the order summary on the review step",
        acceptance_criteria: Enum.join(reviewed_criteria, "\n"),
        key_files: [
          %{
            file_path: "lib/storefront/shipping/estimate.ex",
            note: "Ask the carrier for a delivery window",
            position: 0
          },
          %{
            file_path: "lib/storefront_web/components/order_summary.ex",
            note: "Show the window under the totals",
            position: 1
          }
        ],
        verification_steps: [
          %{
            step_type: "command",
            step_text: "mix test test/storefront/shipping",
            expected_result: "All tests pass",
            position: 0
          },
          %{
            step_type: "manual",
            step_text: "Switch between Standard and Express on the review step",
            expected_result: "The delivery date changes with the method",
            position: 1
          }
        ],
        pitfalls: ["Don't invent a date when the carrier gives none"],
        security_considerations: ["Send the carrier only the postcode, never the full address"],
        testing_strategy: %{
          "unit_tests" => ["Estimate.for_method/2 with and without a carrier window"],
          "integration_tests" => ["The checkout refreshes the estimate when the method changes"],
          "manual_tests" => ["Check the estimate on the review step at 375px"]
        },
        behaviour_test_matrix: reviewed_matrix,
        telemetry_event: "[:storefront, :shipping, :estimate]",
        metrics_to_track: "Share of checkouts that show an estimate; carrier quote latency",
        logging_requirements: "Log carrier errors at warning level with the carrier and service",
        created_by_id: maya.id,
        claimed_at: ago.(30),
        completed_at: ago.(27),
        completed_by_agent: "Claude Opus 5.5",
        completed_by_id: priya.id,
        completion_summary:
          "Added Estimate.for_method/2 and a delivery line in the order summary that follows the shipping method.",
        completion_notes:
          "The carrier sandbox returns no window for PO boxes, so those orders show no date. Checked Standard and Express at 375px.",
        actual_complexity: :medium,
        actual_files_changed: Enum.map_join(reviewed_diffs, ", ", & &1["path"]),
        time_spent_minutes: 95,
        changed_files: reviewed_diffs,
        workflow_steps: demo_workflow_steps.(0),
        explorer_result: %{
          "dispatched" => true,
          "duration_ms" => 52_000,
          "summary" =>
            "The carrier client already returns quotes; the order summary had no slot for a date."
        },
        reviewer_result: %{
          "dispatched" => true,
          "schema_version" => "1.0",
          "status" => "approved",
          "summary" =>
            "All three acceptance criteria are met, and every matrix row has a passing test or a reason.",
          "duration_ms" => 61_000,
          "acceptance_criteria_checked" => length(reviewed_criteria),
          "issues_found" => 0,
          "issues" => [],
          "acceptance_criteria" =>
            Enum.map(reviewed_criteria, fn criterion ->
              %{
                "criterion" => criterion,
                "status" => "met",
                "evidence" => "test/storefront/shipping/estimate_test.exs"
              }
            end),
          "project_checks" => [],
          "testing_strategy" => %{"status" => "passed"},
          "patterns" => %{"status" => "passed"},
          "pitfalls" => %{"status" => "passed"},
          "security_considerations" => %{"status" => "passed"}
        },
        needs_review: true,
        review_status: :approved,
        reviewed_at: ago.(26),
        reviewed_by_id: maya.id,
        review_notes: "Looks good on my phone. Ship it.",
        inserted_hours_ago: 96
      },
      [],
      maya
    )

    :created
  end
end

{:ok, reviewed_task} =
  Repo.transaction(fn -> ensure_reviewed_task.(owned_board.(maya, "Checkout Revamp")) end)

viewer_boards =
  for name <- ["Checkout Revamp", "Marketing Site Launch"],
      viewer && ensure_member.(owned_board.(maya, name), viewer, maya) == :member,
      do: name

summary = %{
  demo_owner: maya.email,
  boards_created: created,
  reviewed_task: reviewed_task,
  boards: ["Checkout Revamp", "Marketing Site Launch"],
  viewer: viewer && viewer.email,
  viewer_member_of: viewer_boards
}

IO.puts("Resources demo data ready: #{inspect(summary)}")
summary
