<script>
  export let title;
  export let products;
</script>

<svelte:head>
  <title>{title}</title>
</svelte:head>

<main class="catalog">
  <h1>{title}</h1>
  <ul>
    {#each products as product}
      <li
        class={product.inStock ? "available" : "sold-out"}
        data-id={product.id}
      >{product.name}: ${(product.priceCents / 100).toFixed(2)}</li>
    {/each}
  </ul>
</main>
