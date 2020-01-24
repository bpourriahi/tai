defmodule Tai.Venues.Account do
  alias __MODULE__

  @type venue_id :: Tai.Venue.id()
  @type credential_id :: Tai.Venue.credential_id()
  @type asset :: atom
  @type t :: %Account{
          venue_id: venue_id,
          credential_id: credential_id,
          asset: asset,
          type: String.t(),
          free: Decimal.t(),
          locked: Decimal.t()
        }

  @enforce_keys ~w(
    venue_id
    credential_id
    asset
    type
    free
    locked
  )a
  defstruct ~w(
    venue_id
    credential_id
    asset
    type
    free
    locked
  )a

  @spec total(t) :: Decimal.t()
  def total(%Account{} = account), do: Decimal.add(account.free, account.locked)
end

defimpl Stored.Item, for: Tai.Venues.Account do
  @type key :: term
  @type account :: Tai.Venues.Account.t()

  @spec key(account) :: key
  def key(a), do: {a.venue_id, a.credential_id, a.asset, a.type}
end
