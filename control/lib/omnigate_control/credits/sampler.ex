defmodule OmnigateControl.Credits.Sampler do
  @moduledoc """
  The clock of the weekly bonus (`OmnigateControl.Credits`): every
  `credits.sample_interval_s` it has `OmnigateControl.Keys.checkpoint/0`
  sample the balances and credit the bonus of every week that has ended,
  including weeks that ended while the control plane was not running.

  Idle unless `credits.bonus_annual_rate` is above zero: without a bonus
  there is nothing to sample for, and the key store is not touched.
  """
  use GenServer
  require Logger

  alias OmnigateControl.{Credits, Keys}

  # The first look comes soon after a start, to close what ended meanwhile.
  @first_ms 3_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sample now (also runs by itself). Returns the bonuses credited."
  def run do
    if Credits.settings().bonus_annual_rate > 0 do
      case Keys.checkpoint() do
        {:ok, bonuses} -> bonuses
        other -> other
      end
    else
      []
    end
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :tick, @first_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:tick, state) do
    try do
      run()
    rescue
      e -> Logger.warning("credit: sampling failed, will try again: #{Exception.message(e)}")
    catch
      :exit, reason -> Logger.warning("credit: sampling failed, will try again: #{inspect(reason)}")
    end

    Process.send_after(self(), :tick, Credits.settings().sample_interval_s * 1_000)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}
end
