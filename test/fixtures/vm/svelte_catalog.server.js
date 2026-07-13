// Generated from svelte_catalog.svelte by svelte@5.56.4.
import * as $ from 'svelte/internal/server';

export default function Svelte_catalog($$renderer, $$props) {
	$$renderer.component(($$renderer) => {
		let title = $$props['title'];
		let products = $$props['products'];

		$.head('1vkpw87', $$renderer, ($$renderer) => {
			$$renderer.title(($$renderer) => {
				$$renderer.push(`<title>${$.escape(title)}</title>`);
			});
		});

		$$renderer.push(`<main class="catalog"><h1>${$.escape(title)}</h1> <ul><!--[-->`);

		const each_array = $.ensure_array_like(products);

		for (let $$index = 0, $$length = each_array.length; $$index < $$length; $$index++) {
			let product = each_array[$$index];

			$$renderer.push(`<li${$.attr_class($.clsx(product.inStock ? "available" : "sold-out"))}${$.attr('data-id', product.id)}>${$.escape(product.name)}: $${$.escape((product.priceCents / 100).toFixed(2))}</li>`);
		}

		$$renderer.push(`<!--]--></ul></main>`);
		$.bind_props($$props, { title, products });
	});
}
