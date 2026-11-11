defmodule OmnigateControl.Guard do
  @moduledoc """
  Keeps a group of processes running without letting their failures reach
  the rest of the application.

  A supervisor that sees too many crashes in a short time gives up and
  exits, and so does the supervisor above it, up to the application. With
  everything under one supervisor that meant four crashes of any store
  inside five seconds stopped the HTTP listener too: one bad input, sent four
  times, was an outage.

  A guard sits between the two. It starts a supervisor for its group
  (`:children`, `:strategy`, registered as `:supervisor_name`) and watches
  it. When that supervisor gives up, the guard does not: it waits (half a
  second at first, doubling up to thirty seconds while the group keeps
  failing, back to half a second once it has stayed up for a minute) and
  starts the group again. The guard itself runs no other code, so it has
  nothing to crash on, and the listener next to it keeps answering: `/healthz`
  says the process is alive, `/readyz` says what is not ready, and requests
  that need the missing piece are refused rather than answered wrongly.

  The first start is different: if the group cannot start at all, the guard
  fails too, and the application does not come up half-working.
  """
  use GenServer
  require Logger

  @min_backoff_ms 500
  @max_backoff_ms 30_000
  @settled_ms 60_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  def child_spec(opts) do
    %{id: Keyword.fetch!(opts, :name), start: {__MODULE__, :start_link, [opts]}, type: :supervisor, shutdown: :infinity}
  end

  @doc "The group's supervisor, or nil while it is down."
  def supervisor(guard), do: GenServer.call(guard, :supervisor)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    state = %{opts: opts, sup: nil, started_ms: 0, backoff_ms: @min_backoff_ms}

    case start_group(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_group(state) do
    opts = state.opts

    case Supervisor.start_link(Keyword.fetch!(opts, :children),
           strategy: Keyword.get(opts, :strategy, :one_for_one),
           name: Keyword.fetch!(opts, :supervisor_name)
         ) do
      {:ok, pid} -> {:ok, %{state | sup: pid, started_ms: System.monotonic_time(:millisecond)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def handle_call(:supervisor, _from, state), do: {:reply, state.sup, state}

  @impl true
  def handle_info({:EXIT, pid, reason}, %{sup: pid} = state) do
    stayed_up = System.monotonic_time(:millisecond) - state.started_ms
    backoff = if stayed_up >= @settled_ms, do: @min_backoff_ms, else: state.backoff_ms

    Logger.error(
      "#{inspect(state.opts[:supervisor_name])} stopped (#{reason |> inspect() |> String.slice(0, 300)}); " <>
        "the HTTP listener stays up, starting the group again in #{backoff} ms"
    )

    Process.send_after(self(), :start_again, backoff)
    {:noreply, %{state | sup: nil, backoff_ms: min(backoff * 2, @max_backoff_ms)}}
  end

  def handle_info(:start_again, %{sup: nil} = state) do
    case start_group(state) do
      {:ok, state} ->
        Logger.info("#{inspect(state.opts[:supervisor_name])} is running again")
        {:noreply, state}

      {:error, reason} ->
        Logger.error(
          "#{inspect(state.opts[:supervisor_name])} could not start (#{reason |> inspect() |> String.slice(0, 300)}); trying again in #{state.backoff_ms} ms"
        )

        Process.send_after(self(), :start_again, state.backoff_ms)
        {:noreply, %{state | backoff_ms: min(state.backoff_ms * 2, @max_backoff_ms)}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Stopped from above (shutdown): take the group down first, in order.
  @impl true
  def terminate(_reason, %{sup: pid}) when is_pid(pid) do
    Supervisor.stop(pid, :shutdown, :infinity)
  catch
    :exit, _ -> :ok
  end

  def terminate(_reason, _state), do: :ok
end
