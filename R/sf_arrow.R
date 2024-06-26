#' @title Create standardized geo metadata for Parquet files
#' @param df object of class \code{sf}
#' @param hf_version dataset version
#' @param license dataset license
#' @param source dataset source
#' @details Reference for metadata standard:
#'   \url{https://github.com/geopandas/geo-arrow-spec}. This is compatible with
#'   \code{GeoPandas} Parquet files. Adopted from \href{https://github.com/wcjochem/sfarrow}{wcjochem/sfarrow}
#' @return JSON formatted list with geo-metadata
#' @keywords internal
#' @importFrom jsonlite toJSON
#' @importFrom sf st_crs

create_metadata <-
  function(df,
           hf_version = "2.2",
           license = "ODbL",
           source = "lynker-spatial") {
    
    warning(strwrap(glue("This is writing {source} supported metadata for hydrofabric version {hf_version}. 
                    Use of the data follows an {license} license."),
                    prefix = "\n", initial = ""
    ), call. = FALSE)
    
    geom_cols <- lapply(df, \(i) inherits(i, "sfc"))
    geom_cols <- names(which(geom_cols == TRUE))
    col_meta <- list()
    
    for (col in geom_cols) {
      col_meta[[col]] <- list(
        crs = sf::st_crs(df[[col]])$wkt,
        encoding = "WKB",
        bbox = as.numeric(sf::st_bbox(df[[col]]))
      )
    }
    
    geo_metadata <- list(
      primary_column = attr(df, "sf_column"),
      columns = col_meta,
      version = hf_version,
      licence = license,
      source = source,
      schema_version = "0.1.0",
      creator = list(library = source)
    )
    
    return(jsonlite::toJSON(geo_metadata, auto_unbox = TRUE))
  }

#' @title Validate Metadata
#' @description Basic checking of key geo metadata columns
#' @param metadata list for geo metadata
#' @return None. Throws an error and stops execution
#' @details Adopted from \href{https://github.com/wcjochem/sfarrow}{wcjochem/sfarrow}
#' @keywords internal

validate_metadata <- function(metadata) {
  if (is.null(metadata) | !is.list(metadata)) {
    stop("Error: empty or malformed geo metadata", call. = F)
  } else{
    # check for presence of required geo keys
    req_names <- c("primary_column", "columns")
    for (n in req_names) {
      if (!n %in% names(metadata)) {
        stop(paste0("Required name: '", n, "' not found in geo metadata"),
             call. = FALSE)
      }
    }
    # check for presence of required geometry columns info
    req_geo_names <- c("crs", "encoding")
    for (c in names(metadata[["columns"]])) {
      geo_col <- metadata[["columns"]][[c]]
      
      for (ng in req_geo_names) {
        if (!ng %in% names(geo_col)) {
          stop(paste0("Required 'geo' metadata item '", ng, "' not found in ", c),
               call. = FALSE)
        }
        if (geo_col[["encoding"]] != "WKB") {
          stop("Only well-known binary (WKB) encoding is currently supported.",
               call. = FALSE)
        }
      }
    }
  }
}

#' @title Encode Well Known Binary
#' @description Convert \code{sfc} geometry columns into a WKB binary format
#' @param df \code{sf} object
#' @details Allows for more than one geometry column in \code{sfc} format. 
#' Adopted from \href{https://github.com/wcjochem/sfarrow}{wcjochem/sfarrow}
#' @return \code{data.frame} with binary geometry column(s)
#' @keywords internal

encode_wkb <- function(df) {
  geom_cols <- lapply(df, \(i)inherits(i, "sfc"))
  geom_cols <- names(which(geom_cols == TRUE))
  
  df <- as.data.frame(df)
  
  for (col in geom_cols) {
    obj_geo <- sf::st_as_binary(df[[col]])
    attr(obj_geo, "class") <-
      c("arrow_binary",
        "vctrs_vctr",
        attr(obj_geo, "class"),
        "list")
    df[[col]] <- obj_geo
  }
  return(df)
}

#' @title Convert Arrow Table to sf
#' @description Helper function to convert 'data.frame' to \code{sf}
#' @param tbl \code{data.frame} from reading an Arrow dataset
#' @param metadata \code{list} of validated geo metadata
#' @details Adopted from \href{https://github.com/wcjochem/sfarrow}{wcjochem/sfarrow}
#' @return object of \code{sf} with CRS and geometry columns
#' @keywords internal

arrow_to_sf <- function(tbl, metadata) {
  
  geom_cols <- names(metadata$columns)
  geom_cols <- intersect(colnames(tbl), geom_cols)
  
  primary_geom <- metadata$primary_column
  
  if (length(geom_cols) < 1) {
    stop("Malformed file and geo metatdata.")
  }
  if (!primary_geom %in% geom_cols) {
    primary_geom <- geom_cols[1]
    warning("Primary geometry column not found, using next available.")
  }
  
  for (col in geom_cols) {
    tbl[[col]] <- sf::st_as_sfc(tbl[[col]],
                                crs = sf::st_crs(metadata$columns[[col]]$crs))
  }
  
  tbl <- sf::st_sf(tbl, sf_column_name = primary_geom)
  return(tbl)
}

#' @title Read a Parquet file to \code{sf} object
#' @description Read a Parquet file. Uses standard metadata information to
#'   identify geometry columns and coordinate reference system information.
#' @param dsn character file path to a data source
#' @param col_select A character vector of column names to keep. Default is
#'   \code{NULL} which returns all columns
#' @param props Now deprecated in \code{\link[arrow]{read_parquet}}.
#' @param ... additional parameters to pass to
#'   \code{\link[arrow]{ParquetFileReader}}
#' @details Reference for the metadata used:
#'   \url{https://github.com/geopandas/geo-arrow-spec}. These are    
#'   standard with the Python \code{GeoPandas} library. 
#'   Adopted from \href{https://github.com/wcjochem/sfarrow}{wcjochem/sfarrow}
#' @seealso \code{\link[arrow]{read_parquet}}, \code{\link[sf]{st_read}}
#' @return object of class \code{\link[sf]{sf}}
#' @export

st_read_parquet <- function(dsn, col_select = NULL,
                            props = NULL, ...){
  if(missing(dsn)){
    stop("Please provide a data source")
  }
  
  if(!is.null(props)){ warning("'props' is deprecated in `arrow`. See arrow::ParquetFileWriter.") }
  
  pq <- arrow::ParquetFileReader$create(dsn, ...)
  schema <- pq$GetSchema()
  metadata <- schema$metadata
  
  if(!"geo" %in% names(metadata)){
    stop("No geometry metadata found. Use arrow::read_parquet")
  } else{
    geo <- jsonlite::fromJSON(metadata$geo)
    validate_metadata(geo)
  }
  
  if(!is.null(col_select)){
    indices <- which(names(schema) %in% col_select) - 1L # 0-indexing
    tbl <- pq$ReadTable(indices)
  } else{
    tbl <- pq$ReadTable()
  }
  
  # covert and create sf
  tbl <- data.frame(tbl)
  tbl <- arrow_to_sf(tbl, geo)
  
  return(tbl)
}

#' Write \code{sf} object to Parquet file
#' @description Convert a simple features spatial object from \code{sf} 
#'   to a Parquet file using \code{\link[arrow]{write_parquet}}. Geometry
#'   columns (type \code{sfc}) are converted to well-known binary (WKB) format.
#' @param obj object of class \code{\link[sf]{sf}}
#' @param dsn data source name. A path and file name with .parquet extension
#' @inheritParams create_metadata
#' @param ... additional options to pass to \code{\link[arrow]{write_parquet}}
#' @return \code{obj} invisibly
#' @details Adopted from \href{https://github.com/wcjochem/sfarrow}{wcjochem/sfarrow}
#' @seealso \code{\link[arrow]{write_parquet}}
#' @export

st_write_parquet <- function(obj, dsn, 
                             hf_version = "2.2",
                             license = "ODbL",
                             source = "lynker-spatial", 
                             ...) {
  if (!inherits(obj, "sf")) { stop("Must be sf data format") }
  
  if (missing(dsn)) { stop("Missing output file") }
  
  geo_metadata <- create_metadata(obj, 
                                  hf_version = hf_version,
                                  license = license,
                                  source = source)
  
  df  <- encode_wkb(obj)
  tbl <- arrow::Table$create(df)
  
  tbl$metadata[["geo"]] <- geo_metadata
  
  arrow::write_parquet(tbl, sink = dsn, ...)
  
  invisible(obj)
}

#' @title Read Parquet Dataset
#' @description Read an Arrow multi-file dataset and create \code{sf} object
#' @param dataset a \code{Dataset} object created by \code{arrow::open_dataset}
#'   or an \code{arrow_dplyr_query}
#' @param find_geom logical. Only needed when returning a subset of columns.
#'   Should all available geometry columns be selected and added to to the
#'   dataset query without being named? Default is \code{FALSE} to require
#'   geometry column(s) to be selected specifically.
#' @details This function is primarily for use after opening a dataset with
#'   \code{arrow::open_dataset}. Users can then query the \code{arrow Dataset}
#'   using \code{dplyr} methods such as \code{\link[dplyr]{filter}} or
#'   \code{\link[dplyr]{select}}. Passing the resulting query to this function
#'   will parse the datasets and create an \code{sf} object. The function
#'   expects consistent geographic metadata to be stored with the dataset in
#'   order to create \code{\link[sf]{sf}} objects. 
#'   Adopted from \href{https://github.com/wcjochem/sfarrow}{wcjochem/sfarrow}
#' @return object of class \code{\link[sf]{sf}}
#' @seealso \code{\link[arrow]{open_dataset}}, \code{\link[sf]{st_read}}, \code{\link{st_read_parquet}}
#' @export

read_sf_dataset <- function(dataset, find_geom = FALSE) {
  if (missing(dataset)) {
    stop("Must provide an Arrow dataset or 'dplyr' arrow query")
  }
  
  if (inherits(dataset, "arrow_dplyr_query")) {
    metadata <- dataset$.data$metadata
  } else{
    metadata <- dataset$metadata
  }
  
  if (!"geo" %in% names(metadata)) {
    stop("No geometry metadata found. Use arrow::read_parquet")
  } else{
    geo <- jsonlite::fromJSON(metadata$geo)
    validate_metadata(geo)
  }
  
  if (find_geom) {
    geom_cols <- names(geo$columns)
    dataset <- dplyr::select(dataset$.data$clone(), c(names(dataset), geom_cols))
  }
  
  # execute query, or read dataset connection
  tbl <- dplyr::collect(dataset)
  tbl <- data.frame(tbl)
  
  tbl <- arrow_to_sf(tbl, geo)
  
  return(tbl)
}

#' @title Write Parquet Dataset
#' @description Write \code{sf} object to an Arrow multi-file dataset
#' @param obj object of class \code{\link[sf]{sf}}
#' @param path string path referencing a directory for the output
#' @param format output file format ("parquet" or "feather")
#' @inheritParams create_metadata
#' @param partitioning character vector of columns in \code{obj} for grouping or
#'   the \code{dplyr::group_vars}
#' @param ... additional arguments and options passed to \code{arrow::write_dataset}
#' @details Translate an \code{sf} spatial object to \code{data.frame} with WKB
#'   geometry columns and then write to an \code{arrow} dataset with
#'   partitioning. Allows for \code{dplyr} grouped datasets (using
#'   \code{\link[dplyr]{group_by}}) and uses those variables to define
#'   partitions. Adopted from \href{https://github.com/wcjochem/sfarrow}{wcjochem/sfarrow}
#' @return \code{obj} invisibly
#' @seealso \code{\link[arrow]{write_dataset}}, \code{\link{st_read_parquet}}
#' @export

write_sf_dataset <- function(obj,
                             path,
                             format = "parquet",
                             partitioning = dplyr::group_vars(obj),
                             hf_version = "2.2",
                             license = "ODbL",
                             source = "lynker-spatial", 
                             ...) {
  if (!inherits(obj, "sf")) {
    stop("Must be an sf data format. Use arrow::write_dataset instead")
  }
  
  if (missing(path)) {
    stop("Must provide a file path for output dataset")
  }
  
  geo_metadata <- create_metadata(obj,
                                  hf_version = hf_version,
                                  license = license,
                                  source = source)
  
  if (inherits(obj, "grouped_df")) {
    partitioning <- force(partitioning)
    dataset <- dplyr::group_modify(obj, ~ encode_wkb(.x))
    dataset <- dplyr::ungroup(dataset)
  } else{
    dataset <- encode_wkb(obj)
  }
  
  tbl <- arrow::Table$create(dataset)
  tbl$metadata[["geo"]] <- geo_metadata
  
  arrow::write_dataset(
    dataset = tbl,
    path = path,
    format = format,
    partitioning = partitioning,
    ...
  )
  
  invisible(obj)
}