-- ============================================================================
-- Case Study: ¿Precio o volumen impulsa el ingreso?
-- Dataset: bigquery-public-data.thelook_ecommerce
-- Ver case_study_price_vs_volume.md para el razonamiento completo de cada paso.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- QUERY 1: Top 3 productos por ingreso, dentro de cada categoría,
-- con clasificación de perfil (impulsado por precio vs. por volumen)
-- relativa a los demás productos de su propia categoría.
-- ----------------------------------------------------------------------------

WITH ingresos_por_producto AS (
  SELECT
    p.category,
    p.name AS producto,
    p.id AS product_id,
    p.retail_price,
    SUM(oi.sale_price) AS ingreso_total,
    COUNT(oi.id) AS unidades_vendidas
  FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
  JOIN `bigquery-public-data.thelook_ecommerce.products` p
    ON oi.product_id = p.id
  -- Solo pedidos que realmente se concretaron
  WHERE oi.status NOT IN ('Cancelled', 'Returned')
  GROUP BY p.category, p.name, p.id, p.retail_price
),

con_percentiles AS (
  SELECT
    *,
    -- Posición relativa (0-1) de este producto en precio, dentro de su categoría
    PERCENT_RANK() OVER (PARTITION BY category ORDER BY retail_price)      AS percentil_precio,
    -- Posición relativa (0-1) de este producto en volumen, dentro de su categoría
    PERCENT_RANK() OVER (PARTITION BY category ORDER BY unidades_vendidas) AS percentil_volumen
  FROM ingresos_por_producto
),

ranked AS (
  SELECT
    *,
    -- product_id como desempate: sin esto, empates en ingreso_total
    -- producen un orden no determinista entre corridas
    ROW_NUMBER() OVER (PARTITION BY category ORDER BY ingreso_total DESC, product_id) AS rn
  FROM con_percentiles
)

SELECT
  category,
  producto,
  retail_price,
  unidades_vendidas,
  ingreso_total,
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


-- ----------------------------------------------------------------------------
-- QUERY 2: Validación a nivel catálogo completo (sin filtrar por top N).
-- Correlación entre percentil de precio / percentil de volumen y el
-- percentil de ingreso, por categoría y en total (GROUP BY ROLLUP).
-- ----------------------------------------------------------------------------

WITH ingresos_por_producto AS (
  SELECT
    p.category,
    p.name AS producto,
    p.id AS product_id,
    p.retail_price,
    SUM(oi.sale_price) AS ingreso_total,
    COUNT(oi.id) AS unidades_vendidas
  FROM `bigquery-public-data.thelook_ecommerce.order_items` oi
  JOIN `bigquery-public-data.thelook_ecommerce.products` p
    ON oi.product_id = p.id
  WHERE oi.status NOT IN ('Cancelled', 'Returned')
  GROUP BY p.category, p.name, p.id, p.retail_price
),

con_percentiles AS (
  SELECT
    *,
    PERCENT_RANK() OVER (PARTITION BY category ORDER BY retail_price)      AS percentil_precio,
    PERCENT_RANK() OVER (PARTITION BY category ORDER BY unidades_vendidas) AS percentil_volumen,
    PERCENT_RANK() OVER (PARTITION BY category ORDER BY ingreso_total)     AS percentil_ingreso
  FROM ingresos_por_producto
),

-- CTE separado para el ROLLUP: mantiene "category" con su NULL real
-- en la fila de totales, antes de renombrarla en el SELECT final.
-- (Si el alias final se llamara igual que la columna original, el
--  ORDER BY resuelve la ambigüedad usando la columna pre-COALESCE,
--  y la fila de totales termina mal ordenada.)
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
  num_productos,
  correlacion_precio_ingreso,
  correlacion_volumen_ingreso
FROM resumen
ORDER BY category IS NULL DESC, correlacion_precio_ingreso DESC;
