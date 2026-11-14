package repository

import (
	"context"
	"testing"

	"retail-store/catalog/config"
)

// Usa la base SQLite en memoria (la misma que usa el servicio por defecto),
// así que no necesita Postgres ni Docker para correr en el CI.
func newTestRepo(t *testing.T) CatalogRepository {
	t.Helper()
	repo, err := NewRepository(config.DatabaseConfiguration{Type: "in-memory"})
	if err != nil {
		t.Fatalf("no se pudo crear el repositorio: %v", err)
	}
	return repo
}

func TestLoadProductData(t *testing.T) {
	products, err := LoadProductData()
	if err != nil {
		t.Fatalf("error leyendo products.json: %v", err)
	}
	if len(products) == 0 {
		t.Fatal("products.json no tiene productos")
	}
	for _, p := range products {
		if p.ID == "" || p.Name == "" || p.Price <= 0 {
			t.Errorf("producto inválido: %+v", p)
		}
	}
}

func TestCountProductsMatchesSeedData(t *testing.T) {
	repo := newTestRepo(t)
	seed, _ := LoadProductData()

	count, err := repo.CountProducts(nil, context.Background())
	if err != nil {
		t.Fatalf("CountProducts falló: %v", err)
	}
	if count != len(seed) {
		t.Errorf("se esperaban %d productos, hay %d", len(seed), count)
	}
}

func TestGetProductsOrderedByPriceAsc(t *testing.T) {
	repo := newTestRepo(t)

	products, err := repo.GetProducts(nil, "price_asc", 1, 100, context.Background())
	if err != nil {
		t.Fatalf("GetProducts falló: %v", err)
	}
	for i := 1; i < len(products); i++ {
		if products[i-1].Price > products[i].Price {
			t.Fatalf("no están ordenados por precio: %d antes que %d", products[i-1].Price, products[i].Price)
		}
	}
}

func TestGetProductsPagination(t *testing.T) {
	repo := newTestRepo(t)

	page, err := repo.GetProducts(nil, "", 1, 3, context.Background())
	if err != nil {
		t.Fatalf("GetProducts falló: %v", err)
	}
	if len(page) != 3 {
		t.Errorf("la página 1 de tamaño 3 trajo %d productos", len(page))
	}
}

func TestGetProductByIDAndNotFound(t *testing.T) {
	repo := newTestRepo(t)
	seed, _ := LoadProductData()

	p, err := repo.GetProduct(seed[0].ID, context.Background())
	if err != nil {
		t.Fatalf("GetProduct falló: %v", err)
	}
	if p.Name != seed[0].Name {
		t.Errorf("nombre esperado %q, obtenido %q", seed[0].Name, p.Name)
	}

	if _, err := repo.GetProduct("no-existe", context.Background()); err == nil {
		t.Error("se esperaba error para un id inexistente")
	}
}

func TestGetTags(t *testing.T) {
	repo := newTestRepo(t)
	seed, _ := LoadProductTagData()

	tags, err := repo.GetTags(context.Background())
	if err != nil {
		t.Fatalf("GetTags falló: %v", err)
	}
	if len(tags) != len(seed) {
		t.Errorf("se esperaban %d tags, hay %d", len(seed), len(tags))
	}
}
