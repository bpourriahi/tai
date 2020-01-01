defmodule Tai.Venues.Boot.AssetBalances do
  @type venue :: Tai.Venue.t()

  @spec hydrate(venue) :: :ok | {:error, reason :: term}
  def hydrate(venue) do
    venue.accounts
    |> Enum.reduce(
      :ok,
      &fetch_and_upsert(&1, &2, venue)
    )
  end

  defp fetch_and_upsert({account_id, _}, :ok, venue) do
    with {:ok, balances} <- Tai.Venues.Client.asset_balances(venue, account_id) do
      Enum.each(balances, &Tai.Venues.AssetBalanceStore.upsert/1)
      :ok
    else
      {:error, _} = error ->
        error
    end
  end

  defp fetch_and_upsert({_, _}, {:error, _} = error, _), do: error
end
