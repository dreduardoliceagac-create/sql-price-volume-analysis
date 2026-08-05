# Case Study: ¿Precio o volumen impulsa el ingreso? (SQL / BigQuery)

**Dataset:** [`bigquery-public-data.thelook_ecommerce`](https://console.cloud.google.com/marketplace/product/bigquery-public-data/thelook-ecommerce) — tablas `order_items` y `products`.
**Herramientas:** BigQuery Standard SQL — CTEs encadenados, funciones de ventana, funciones de correlación, `GROUP BY ROLLUP`.

## La pregunta de negocio

Un escenario típico de category management/trade marketing:

> *"Necesitamos priorizar qué SKUs promocionar la próxima campaña. Dame los 3 productos con mayor ingreso dentro de cada categoría, considerando solo pedidos que realmente se concretaron. Después: ¿esos productos ganan por ser caros, o por venderse en volumen?"*

Lo interesante de este ejercicio no es la query final — es que la primera versión "razonable" de la métrica resultó estar sesgada dos veces distintas antes de llegar a una respuesta confiable. Documentar ese proceso es, de hecho, el valor real del ejercicio.

---

## Intento 1 — Top 3 por categoría (la base)

```sql
WITH ingresos_por_producto AS (
  SELECT
    p.category,
    p.name AS producto,
    p.id AS product_id,
    SUM(oi.sale_price) AS ingreso_total,
    COUNT(oi.id) AS unidades_vendidas
  FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
  JOIN `bigquery-public-data.thelook_ecommerce.products` p
    ON oi.product_id = p.id
  WHERE oi.status NOT IN ('Cancelled', 'Returned')
  GROUP BY p.category, p.name, p.id
),
ranked AS (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY category ORDER BY ingreso_total DESC, product_id) AS rn
  FROM ingresos_por_producto
)
SELECT category, producto, ingreso_total, unidades_vendidas
FROM ranked
WHERE rn <= 3
ORDER BY category, rn;
```

**Patrón usado:** "top N por grupo" con `ROW_NUMBER() OVER (PARTITION BY ... ORDER BY ...)`. El desempate explícito (`product_id` como segundo criterio) es deliberado — sin él, un empate en `ingreso_total` produce un orden no determinista entre corridas.

**Resultado:** 78 filas = 26 categorías × 3. Correcto.

---

## Intento 2 — Clasificar por "precio alto" con un umbral fijo ❌

Primera hipótesis de clasificación: si `retail_price >= $200`, es un producto "premium".

**Resultado:** ~90% de los productos del top 3 caían en "precio alto". El umbral no discriminaba nada — porque $200 no significa lo mismo en Accesorios que en Chamarras. Un corte absoluto aplicado a categorías con rangos de precio muy distintos no es una métrica comparable.

---

## Intento 3 — Comparar contra el promedio de la categoría ❌ (sesgo distinto)

Segundo intento: comparar el precio de cada producto contra el precio promedio de **su propia categoría**, usando una función de ventana sin `ORDER BY`:

```sql
AVG(retail_price) OVER (PARTITION BY category) AS precio_promedio_categoria
```

**Resultado:** ~92% seguía cayendo en "precio alto". El umbral relativo tampoco resolvió el problema — porque el filtro real (`WHERE rn <= 3`) ya había preseleccionado únicamente a los **ganadores** de ingreso. Comparar ganadores contra el promedio de *toda* la categoría (incluyendo a los perdedores) favorece casi por definición al precio, ya que ingreso = precio × volumen, y es matemáticamente más fácil llegar al top siendo caro que siendo barato. Esto es un **sesgo de selección clásico**: la muestra ya estaba filtrada por la variable que se intentaba explicar.

---

## Intento 4 — Percentiles relativos en ambos ejes ✅

La corrección: en vez de "¿superaste un promedio global?", la pregunta correcta es **"¿en cuál de tus dos atributos destacas más frente a tus propios competidores de categoría?"** — usando `PERCENT_RANK()` para posicionar cada producto en una escala de 0 a 1 tanto en precio como en volumen, dentro de su categoría.

```sql
WITH ingresos_por_producto AS (
  SELECT
    p.category, p.name AS producto, p.id AS product_id, p.retail_price,
    SUM(oi.sale_price) AS ingreso_total,
    COUNT(oi.id) AS unidades_vendidas
  FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
  JOIN `bigquery-public-data.thelook_ecommerce.products` p ON oi.product_id = p.id
  WHERE oi.status NOT IN ('Cancelled', 'Returned')
  GROUP BY p.category, p.name, p.id, p.retail_price
),
con_percentiles AS (
  SELECT *,
    PERCENT_RANK() OVER (PARTITION BY category ORDER BY retail_price)      AS percentil_precio,
    PERCENT_RANK() OVER (PARTITION BY category ORDER BY unidades_vendidas) AS percentil_volumen
  FROM ingresos_por_producto
),
ranked AS (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY category ORDER BY ingreso_total DESC, product_id) AS rn
  FROM con_percentiles
)
SELECT
  category, producto, retail_price, unidades_vendidas, ingreso_total,
  ROUND(percentil_precio, 2)  AS percentil_precio,
  ROUND(percentil_volumen, 2) AS percentil_volumen,
  CASE
    WHEN percentil_precio > percentil_volumen THEN 'Impulsado más por precio'
    WHEN percentil_volumen > percentil_precio THEN 'Impulsado más por volumen'
    ELSE 'Equilibrado'
  END AS perfil
FROM ranked
WHERE rn <= 3
ORDER BY category, rn;
```

**Resultado:** 12 de 13 productos revisados salieron "impulsados más por precio", con una sola excepción casi empatada por volumen. Un patrón mucho más creíble — pero con una advertencia pendiente: esto **sigue siendo solo el top 3**, la muestra sesgada. La pregunta abierta era si el patrón se sostenía en todo el catálogo o era un artefacto de mirar solo a los ganadores.

---

## Validación final — Todo el catálogo, sin filtrar por ganadores ✅

```sql
WITH ingresos_por_producto AS (
  SELECT
    p.category, p.name AS producto, p.id AS product_id, p.retail_price,
    SUM(oi.sale_price) AS ingreso_total,
    COUNT(oi.id) AS unidades_vendidas
  FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
  JOIN `bigquery-public-data.thelook_ecommerce.products` p ON oi.product_id = p.id
  WHERE oi.status NOT IN ('Cancelled', 'Returned')
  GROUP BY p.category, p.name, p.id, p.retail_price
),
con_percentiles AS (
  SELECT *,
    PERCENT_RANK() OVER (PARTITION BY category ORDER BY retail_price)      AS percentil_precio,
    PERCENT_RANK() OVER (PARTITION BY category ORDER BY unidades_vendidas) AS percentil_volumen,
    PERCENT_RANK() OVER (PARTITION BY category ORDER BY ingreso_total)     AS percentil_ingreso
  FROM ingresos_por_producto
),
resumen AS (
  SELECT
    category,
    COUNT(*) AS num_productos,
    ROUND(CORR(percentil_precio, percentil_ingreso), 3)  AS correlacion_precio_ingreso,
    ROUND(CORR(percentil_volumen, percentil_ingreso), 3) AS correlacion_volumen_ingreso
  FROM con_percentiles
  GROUP BY ROLLUP(category)
)
SELECT
  COALESCE(category, 'TODAS LAS CATEGORÍAS') AS category_label,
  num_productos, correlacion_precio_ingreso, correlacion_volumen_ingreso
FROM resumen
ORDER BY category IS NULL DESC, correlacion_precio_ingreso DESC;
```

**Por qué esta versión es metodológicamente más sólida:**
- Se quitó el filtro `WHERE rn <= 3` — ya no se compara solo a los ganadores, sino a los ~28,790 productos del catálogo completo.
- `CORR()` (coeficiente de Pearson) sobre percentiles, no sobre valores crudos — más robusto ante outliers de precio o de volumen.
- `GROUP BY ROLLUP(category)` calcula el desglose por categoría **y** el total agregado en una sola pasada, sin duplicar la query.

---

## Hallazgos finales

| Nivel de análisis | Correlación precio–ingreso | Correlación volumen–ingreso |
|---|---|---|
| Top 3 por categoría (muestra sesgada) | ~0.95+ en casi todas | ~0.4–0.6 |
| Catálogo completo (28,790 productos) | **0.769** | **0.582** |

- **El precio es, de forma consistente, el mejor predictor de ingreso** en la enorme mayoría de las categorías — tanto entre los ganadores como en el catálogo completo, aunque el margen se modera notablemente al incluir a toda la población (de una ventaja casi absoluta a una diferencia de ~32%).
- **Excepciones identificadas:** en *Clothing Sets*, *Suits*, *Socks & Hosiery* y *Underwear*, el volumen supera al precio como predictor. Con una lectura de negocio razonable: son categorías de reposición/necesidad (ropa interior, calcetería) más que de compra por estatus o deseo — encaja con la intuición de que ahí el ingreso se explica por cuánto se vende, no por qué tan caro es cada artículo.
- **Advertencia de tamaño de muestra:** *Clothing Sets* tiene solo 35 productos frente a cientos o miles en el resto de las categorías — su resultado se trata con más cautela que el de *Underwear* (1,085 productos) o *Socks & Hosiery* (661), donde el tamaño de muestra respalda mejor la conclusión.

---

## La lección metodológica (el verdadero punto del ejercicio)

Cada iteración de este análisis falló por una razón distinta, y las tres son errores reales que se cometen en análisis de datos profesional, no errores de sintaxis:

1. **Umbral absoluto sin normalizar por grupo** — comparar peras con manzanas entre categorías de rangos de precio muy distintos.
2. **Sesgo de selección** — comparar una muestra ya filtrada por la variable que se busca explicar (ingreso) contra un promedio que incluye a quienes no pasaron ese filtro.
3. **Generalizar desde una muestra sesgada** — concluir sobre "toda la tienda" a partir de solo los top 3 de cada categoría, sin validar si el patrón se sostenía en la población completa.

La fuerza aparente de un patrón puede depender enormemente de si se está analizando la población completa o un subconjunto ya filtrado por el resultado que se busca explicar. Detectar esto a tiempo — y corregirlo con un enfoque distinto en vez de forzar la métrica original — es la diferencia entre un análisis que confirma lo que uno espera ver y uno que realmente lo pone a prueba.

---

### Notas
- Sintaxis en BigQuery Standard SQL. `CORR()`, `PERCENT_RANK()` y `GROUP BY ROLLUP` están disponibles en la mayoría de motores SQL modernos (PostgreSQL, Snowflake, BigQuery) con sintaxis equivalente o casi idéntica.
- Dataset público, sin datos sensibles — seguro de compartir tal cual.
