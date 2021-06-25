defmodule SpiderWeb.SpiderLive do
  use SpiderWeb, :live_view

  @url ""

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Spider.PubSub, "spider")

    count = 0
    categories = %{}
    products = []

    {:ok,
     socket
     |> assign(:categories, categories)
     |> assign(:count, count)
     |> assign(:products, products)}
  end

  @impl true
  def handle_event("select", %{"name" => name}, socket) do
    products =
      socket.assigns.categories
      |> Enum.find(fn {k, _v} -> k == name end)
      |> elem(1)
      |> Map.get(:products)

    {:noreply, socket |> assign(:products, products) |> assign(:selected, name)}
  end

  @impl true
  def handle_event("crawl", _params, socket) do
    cookie = login()

    headers = [{"Cookie", cookie}]

    {:ok, %{body: page}} = HTTPoison.get("#{@url}/categories", headers)

    categories =
      Floki.find(page, ".cateogry-tile-item .title")
      |> Enum.reduce(%{}, fn cat, acc ->
        name = Floki.find(cat, "span") |> Floki.text()
        link = Floki.find(cat, "a") |> Floki.attribute("href") |> List.first()
        Map.put(acc, name, %{count: 0, link: link, products: []})
      end)

    spawn(fn ->
      do_scrape(categories, headers)
    end)

    {selected, _} = Enum.at(categories, 0)

    {:noreply, socket |> assign(:categories, categories) |> assign(:selected, selected)}
  end

  defp do_scrape(categories, headers) do
    Enum.each(categories, fn {name, cat} ->
      case HTTPoison.get("#{@url}#{cat.link}", headers, timeout: 50_000, recv_timeout: 50_000) do
        {:ok, %{body: page}} ->
          subcat_link =
            Floki.find(page, ".cateogry-tile-item .title")
            |> Enum.take(1)
            |> Floki.find("a")
            |> Floki.attribute("href")

          scrape(name, subcat_link, headers)

        ded ->
          IO.inspect(ded)
      end
    end)
  end

  defp scrape(cat_name, subcat_link, headers) do
    case HTTPoison.get("#{@url}#{subcat_link}", headers, timeout: 50_000, recv_timeout: 50_000) do
      {:ok, %{body: page}} ->
        Floki.find(page, ".cateogry-tile-item .title")
        |> case do
          [] ->
            Floki.find(page, "#product-grid .product")
            |> Enum.each(fn product ->
              name = Floki.find(product, ".widget-productlist-title a") |> Floki.text()
              price = Floki.find(product, ".item-price") |> Floki.text()
              img = Floki.find(product, ".product-img") |> Floki.attribute("src")

              product = %{name: name, price: price, img: "#{@url}#{img}"}

              Phoenix.PubSub.broadcast(
                Spider.PubSub,
                "spider",
                {:product_scraped, cat_name, product}
              )
            end)

          subcats ->
            subcat_link =
              subcats
              |> Enum.take(1)
              |> Floki.find("a")
              |> Floki.attribute("href")

            scrape(cat_name, subcat_link, headers)
        end

      ded ->
        IO.inspect(ded)
    end
  end

  defp login() do
    {:ok, %{headers: headers}} =
      HTTPoison.post(
        "loginurl",
        Jason.encode!(%{password: "password", username: "username"}),
        [{"Content-Type", "application/json"}]
      )

    {_, cookie} = List.keyfind(headers, "Set-Cookie", 0)
    cookie
  end

  @impl true
  def handle_info(
        {:product_scraped, name, product},
        %{assigns: %{categories: categories}} = socket
      ) do
    {products, categories} = get_and_update_in(categories[name][:products], &{&1, [product | &1]})
    categories = update_in(categories[name][:count], &(&1 + 1))
    count = socket.assigns.count + 1

    case socket.assigns.selected == name do
      true ->
        {:noreply,
         socket
         |> assign(:categories, categories)
         |> assign(:count, count)
         |> assign(:products, products)}

      false ->
        {:noreply,
         socket
         |> assign(:categories, categories)
         |> assign(:count, count)}
    end
  end
end
