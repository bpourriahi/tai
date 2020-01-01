defmodule Tai.Venues.Adapters.Gdax.ProductsTest do
  use ExUnit.Case, async: false
  use ExVCR.Mock, adapter: ExVCR.Adapter.Hackney

  @test_venues Tai.TestSupport.Helpers.test_venue_adapters()

  setup_all do
    HTTPoison.start()
    venue = @test_venues |> Map.fetch!(:gdax)
    {:ok, %{venue: venue}}
  end

  test "retrieves the trade rules for each product", %{venue: venue} do
    use_cassette "venue_adapters/shared/products/gdax/success" do
      assert {:ok, products} = Tai.Venues.Client.products(venue)
      assert %Tai.Venues.Product{} = product = find_product_by_symbol(products, :ltc_btc)
      assert Decimal.cmp(product.min_notional, Decimal.new("0.000001")) == :eq
      assert Decimal.cmp(product.min_price, Decimal.new("0.00001")) == :eq
      assert Decimal.cmp(product.min_size, Decimal.new("0.1")) == :eq
      assert Decimal.cmp(product.max_size, Decimal.new(2000)) == :eq
      assert Decimal.cmp(product.price_increment, Decimal.new("0.00001")) == :eq
      assert Decimal.cmp(product.size_increment, Decimal.new("0.1")) == :eq
    end
  end

  test "returns an error tuple when the passphrase is invalid", %{venue: venue} do
    use_cassette "venue_adapters/shared/products/gdax/error_invalid_passphrase" do
      assert {:error, {:credentials, reason}} = Tai.Venues.Client.products(venue)
      assert reason == "Invalid Passphrase"
    end
  end

  test "returns an error tuple when the api key is invalid", %{venue: venue} do
    use_cassette "venue_adapters/shared/products/gdax/error_invalid_api_key" do
      assert {:error, {:credentials, reason}} = Tai.Venues.Client.products(venue)
      assert reason == "Invalid API Key"
    end
  end

  test "returns an error tuple when the request times out", %{venue: venue} do
    use_cassette "venue_adapters/shared/products/gdax/error_timeout" do
      assert Tai.Venues.Client.products(venue) == {:error, :timeout}
    end
  end

  test "returns an error tuple when down for maintenance", %{venue: venue} do
    use_cassette "venue_adapters/shared/products/gdax/error_maintenance" do
      assert {:error, reason} = Tai.Venues.Client.products(venue)

      assert reason ==
               {:service_unavailable,
                "GDAX is currently under maintenance. For updates please see https://status.gdax.com/"}
    end
  end

  def find_product_by_symbol(products, symbol) do
    Enum.find(products, &(&1.symbol == symbol))
  end
end
