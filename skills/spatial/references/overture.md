# Overture Maps Reference

Overture Maps is a free, open global dataset — POIs, buildings, roads, boundaries — distributed as GeoParquet on S3. No API keys, no downloads, no registration.

## Access

```sql
LOAD httpfs;
LOAD spatial;
CREATE SECRET (TYPE S3, PROVIDER config, REGION 'us-west-2');
```

## S3 paths

Use the STAC catalog to find the latest release; Overture keeps only the last few, so an older
path stops resolving (2026-03-18.0 was gone by 2026-10-17, when the latest was `2026-09-23.1`):

```sql
SELECT latest FROM read_json($cmd$curl -sSL --fail --max-time 30 https://stac.overturemaps.org/catalog.json |$cmd$);
```

Base path: `s3://overturemaps-us-west-2/release/<RELEASE>/`

| Theme | Type | Path suffix |
|-------|------|-------------|
| Places (POIs) | place | `theme=places/type=place/*` |
| Buildings | building | `theme=buildings/type=building/*` |
| Transportation | segment | `theme=transportation/type=segment/*` |
| Divisions (admin boundaries) | division | `theme=divisions/type=division/*` |
| Division areas (polygons) | division_area | `theme=divisions/type=division_area/*` |
| Addresses | address | `theme=addresses/type=address/*` |
| Base (land, water, land_use) | various | `theme=base/type=land/*` etc. |

## Efficient querying — bbox filtering

Overture files are partitioned by bounding box. Use `bbox.*` columns for predicate pushdown — this avoids downloading the entire dataset:

```sql
FROM read_parquet('s3://overturemaps-us-west-2/release/2026-09-23.1/theme=places/type=place/*')
WHERE bbox.xmin > -74.00 AND bbox.xmax < -73.97
  AND bbox.ymin > 40.74 AND bbox.ymax < 40.76
```

Always filter on bbox first, then apply additional filters.

## Schema: Places

| Field | Type | Description |
|-------|------|-------------|
| `id` | VARCHAR | Unique identifier |
| `geometry` | GEOMETRY | Point location |
| `bbox.xmin/xmax/ymin/ymax` | DOUBLE | Bounding box (for pushdown) |
| `names.primary` | VARCHAR | Primary name |
| `taxonomy.primary` | VARCHAR | Primary category (e.g., `coffee_shop`, `restaurant`, `hospital`); replaced `categories.primary` |
| `taxonomy.hierarchy` | VARCHAR[] | Category path from the root |
| `taxonomy.alternates` | VARCHAR[] | Additional categories |
| `basic_category` | VARCHAR | Coarser category |
| `confidence` | DOUBLE | 0–1 confidence score |
| `addresses[1].freeform` | VARCHAR | Full address text |
| `addresses[1].locality` | VARCHAR | City/town |
| `addresses[1].country` | VARCHAR | Country code |
| `websites` | VARCHAR[] | URLs |
| `phones` | VARCHAR[] | Phone numbers |
| `brand.names.primary` | VARCHAR | Brand name |

## Schema: Buildings

| Field | Type | Description |
|-------|------|-------------|
| `id` | VARCHAR | Unique identifier |
| `geometry` | GEOMETRY | Polygon footprint |
| `names.primary` | VARCHAR | Building name (often null) |
| `class` | VARCHAR | Building class |
| `height` | DOUBLE | Height in meters |
| `num_floors` | INTEGER | Number of floors |
| `roof_shape` | VARCHAR | Roof shape |

## Schema: Divisions

| Field | Type | Description |
|-------|------|-------------|
| `id` | VARCHAR | Unique identifier |
| `geometry` | GEOMETRY | Point (representative location) |
| `names.primary` | VARCHAR | Division name |
| `subtype` | VARCHAR | `country`, `region`, `county`, `locality`, etc. |
| `admin_level` | INTEGER | Hierarchy level |
| `population` | INTEGER | Population |
| `country` | VARCHAR | ISO 3166-1 alpha-2 |

## Schema: Division Areas (boundaries)

| Field | Type | Description |
|-------|------|-------------|
| `id` | VARCHAR | Unique identifier |
| `geometry` | GEOMETRY | MultiPolygon boundary |
| `division_id` | VARCHAR | Links to division |
| `names.primary` | VARCHAR | Area name |
| `subtype` | VARCHAR | Same as divisions |
| `country` | VARCHAR | ISO 3166-1 alpha-2 |

## Schema: Transportation Segments

| Field | Type | Description |
|-------|------|-------------|
| `id` | VARCHAR | Unique identifier |
| `geometry` | GEOMETRY | LineString centerline |
| `names.primary` | VARCHAR | Road name |
| `class` | VARCHAR | Road class (motorway, primary, secondary, tertiary, residential, etc.) |
| `subtype` | VARCHAR | road, rail, water |
| `speed_limits` | STRUCT[] | Speed limit rules |

## Common queries

### Find places by category near a point
```sql
SELECT names.primary, taxonomy.primary, confidence,
       ST_Distance_Spheroid(
         ST_Point(ST_X(geometry), ST_Y(geometry))::POINT_2D,
         ST_Point(-73.985, 40.748)::POINT_2D
       ) AS dist_m
FROM read_parquet('s3://overturemaps-us-west-2/release/2026-09-23.1/theme=places/type=place/*')
WHERE bbox.xmin BETWEEN -74.01 AND -73.96
  AND bbox.ymin BETWEEN 40.72 AND 40.77
  AND taxonomy.primary = 'coffee_shop'
ORDER BY dist_m
LIMIT 10;
```

### Count buildings in a city
```sql
SELECT count(id) AS buildings
FROM read_parquet('s3://overturemaps-us-west-2/release/2026-09-23.1/theme=buildings/type=building/*')
WHERE bbox.xmin BETWEEN -122.75 AND -122.55
  AND bbox.ymin BETWEEN 45.45 AND 45.60;
```

### Join user data with Overture
The nearest Overture place to each row of a user's CSV. Each row becomes its own statement with a
literal bbox, so every read gets Parquet pushdown; a correlated join would scan the release.

```sql
WITH user_points AS (
    SELECT longitude, latitude,
           longitude - 0.01 AS xmin, longitude + 0.01 AS xmax, latitude - 0.01 AS ymin, latitude + 0.01 AS ymax,
           's3://overturemaps-us-west-2/release/2026-09-23.1/theme=places/type=place/*' AS places
    FROM 'user_locations.csv'
), rendered AS (
    SELECT tera_render($tera$
        SELECT {{ longitude }} AS longitude, {{ latitude }} AS latitude,
               min_by(names.primary, dist_m) AS nearest_place, min_by(taxonomy.primary, dist_m) AS category, min(dist_m) AS dist_m
        FROM (
            SELECT names, taxonomy,
                   ST_Distance_Spheroid(ST_Point(ST_X(geometry), ST_Y(geometry))::POINT_2D,
                                        ST_Point({{ longitude }}, {{ latitude }})::POINT_2D) AS dist_m
            FROM read_parquet('{{ places }}')
            WHERE bbox.xmin BETWEEN {{ xmin }} AND {{ xmax }}
              AND bbox.ymin BETWEEN {{ ymin }} AND {{ ymax }}
        )
    $tera$, user_points::JSON, autoescape := false) AS sql
    FROM user_points
), dispatched AS (
    SELECT array_agg(selfdispatch(sql)) AS receipts FROM rendered
)
SELECT receipt.* FROM dispatched CROSS JOIN UNNEST(receipts) AS t(receipt);
```

Verified 2026-10-17 on dev with two Manhattan points in place of the CSV: one receipt each, the
nearest place within 5 m. The coffee-shop query returned 5 rows for a 0.01° box; the buildings
count was checked on a 0.01° box (159).
