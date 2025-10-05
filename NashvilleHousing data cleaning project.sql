/*******************************************************
  Cleaning & Normalizing NashvilleHousing (PortfolioProject1)
  - Safe checks for existing columns
  - Transactional updates for risky operations
  - Comments and examples for import via BULK/OPENROWSET (commented)
*******************************************************/

USE PortfolioProject1;
GO

-- Quick preview
SELECT TOP (50) *
FROM dbo.NashvilleHousing;
GO

/* ======================================================
   1) STANDARDIZE / CONVERT SaleDate
   - If SaleDate is already DATE this will be harmless.
   - If conversion fails for some rows, we create a SaleDateConverted column and store results there.
   ====================================================== */

-- Show current values and attempted conversion
SELECT SaleDate,
       TRY_CONVERT(date, SaleDate) AS SaleDate_TryConvert
FROM dbo.NashvilleHousing;
GO

-- If SaleDate column is character and conversion is safe for most rows, update in-place inside a transaction.
BEGIN TRY
    BEGIN TRAN;

    -- Attempt to update in-place. This will set to NULL for values that fail TRY_CONVERT.
    UPDATE dbo.NashvilleHousing
    SET SaleDate = TRY_CONVERT(date, SaleDate)
    WHERE SaleDate IS NOT NULL;  -- optional: limit to non-null to speed up

    COMMIT TRAN;
END TRY
BEGIN CATCH
    ROLLBACK TRAN;
    PRINT 'In-place update failed. Will fallback to adding SaleDateConverted column.';
END CATCH;
GO

-- Add SaleDateConverted if it doesn't exist and populate with converted dates (safe approach)
IF COL_LENGTH('dbo.NashvilleHousing', 'SaleDateConverted') IS NULL
BEGIN
    ALTER TABLE dbo.NashvilleHousing
    ADD SaleDateConverted DATE;
END
GO

UPDATE dbo.NashvilleHousing
SET SaleDateConverted = TRY_CONVERT(date, SaleDate);
GO

-- Verify rows where conversion still failed (both are NULL or invalid)
SELECT *
FROM dbo.NashvilleHousing
WHERE SaleDate IS NOT NULL AND TRY_CONVERT(date, SaleDate) IS NULL;
GO

/* ======================================================
   2) POPULATE MISSING PropertyAddress USING OTHER ROWS (same ParcelID)
   - Use self-join to pull non-null address for same ParcelID
   ====================================================== */

-- Show which ParcelIDs have NULL PropertyAddress
SELECT ParcelID, COUNT(*) AS RowsPerParcel, SUM(CASE WHEN PropertyAddress IS NULL THEN 1 ELSE 0 END) AS NullAddressCount
FROM dbo.NashvilleHousing
GROUP BY ParcelID
HAVING SUM(CASE WHEN PropertyAddress IS NULL THEN 1 ELSE 0 END) > 0
ORDER BY NullAddressCount DESC;
GO

-- Preview candidate join rows
SELECT a.UniqueID AS MissingUID, a.ParcelID, a.PropertyAddress AS A_PropertyAddress,
       b.UniqueID AS SourceUID, b.PropertyAddress AS B_PropertyAddress
FROM dbo.NashvilleHousing AS a
JOIN dbo.NashvilleHousing AS b
    ON a.ParcelID = b.ParcelID
   AND a.UniqueID <> b.UniqueID
WHERE a.PropertyAddress IS NULL
  AND b.PropertyAddress IS NOT NULL;
GO

-- Update NULL PropertyAddress values using any non-null PropertyAddress for same ParcelID.
-- Use TOP (1) with CROSS APPLY to avoid multi-row update ambiguity.
BEGIN TRAN;
UPDATE a
SET PropertyAddress = s.SourceAddress
FROM dbo.NashvilleHousing a
CROSS APPLY (
    SELECT TOP (1) b.PropertyAddress AS SourceAddress
    FROM dbo.NashvilleHousing b
    WHERE b.ParcelID = a.ParcelID
      AND b.PropertyAddress IS NOT NULL
    ORDER BY b.UniqueID
) s
WHERE a.PropertyAddress IS NULL
  AND s.SourceAddress IS NOT NULL;
COMMIT TRAN;
GO

-- Verify
SELECT ParcelID, PropertyAddress
FROM dbo.NashvilleHousing
WHERE PropertyAddress IS NULL
ORDER BY ParcelID;
GO

/* ======================================================
   3) SPLIT PropertyAddress INTO ADDRESS & CITY (safe handling)
   - We assume format: "<AddressPart>, <CityPart>" but guard for missing comma.
   - Adds PropertySplitAddress and PropertySplitCity if not present.
   ====================================================== */

IF COL_LENGTH('dbo.NashvilleHousing', 'PropertySplitAddress') IS NULL
BEGIN
    ALTER TABLE dbo.NashvilleHousing
    ADD PropertySplitAddress NVARCHAR(255);
END

IF COL_LENGTH('dbo.NashvilleHousing', 'PropertySplitCity') IS NULL
BEGIN
    ALTER TABLE dbo.NashvilleHousing
    ADD PropertySplitCity NVARCHAR(255);
END
GO

-- Populate splits. Use conditional logic to handle addresses without comma.
UPDATE dbo.NashvilleHousing
SET PropertySplitAddress = CASE
        WHEN PropertyAddress IS NULL THEN NULL
        WHEN CHARINDEX(',', PropertyAddress) > 0 THEN LTRIM(RTRIM(SUBSTRING(PropertyAddress, 1, CHARINDEX(',', PropertyAddress) - 1)))
        ELSE LTRIM(RTRIM(PropertyAddress))
    END,
    PropertySplitCity = CASE
        WHEN PropertyAddress IS NULL THEN NULL
        WHEN CHARINDEX(',', PropertyAddress) > 0 THEN LTRIM(RTRIM(SUBSTRING(PropertyAddress, CHARINDEX(',', PropertyAddress) + 1, 8000)))
        ELSE NULL
    END;
GO

-- Quick sample check
SELECT TOP (100) PropertyAddress, PropertySplitAddress, PropertySplitCity
FROM dbo.NashvilleHousing
ORDER BY ParcelID;
GO

/* ======================================================
   4) SPLIT OwnerAddress USING PARSENAME (works if comma-separated and up to 3 parts)
   - We'll transform commas to dots and use PARSENAME, but guard for NULLs.
   ====================================================== */

IF COL_LENGTH('dbo.NashvilleHousing', 'OwnerSplitAddress') IS NULL
BEGIN
    ALTER TABLE dbo.NashvilleHousing
    ADD OwnerSplitAddress NVARCHAR(255);
END

IF COL_LENGTH('dbo.NashvilleHousing', 'OwnerSplitCity') IS NULL
BEGIN
    ALTER TABLE dbo.NashvilleHousing
    ADD OwnerSplitCity NVARCHAR(255);
END

IF COL_LENGTH('dbo.NashvilleHousing', 'OwnerSplitState') IS NULL
BEGIN
    ALTER TABLE dbo.NashvilleHousing
    ADD OwnerSplitState NVARCHAR(255);
END
GO

UPDATE dbo.NashvilleHousing
SET OwnerSplitAddress = CASE WHEN OwnerAddress IS NULL THEN NULL
    ELSE LTRIM(RTRIM(PARSENAME(REPLACE(OwnerAddress, ',', '.'), 3))) END,
    OwnerSplitCity    = CASE WHEN OwnerAddress IS NULL THEN NULL
    ELSE LTRIM(RTRIM(PARSENAME(REPLACE(OwnerAddress, ',', '.'), 2))) END,
    OwnerSplitState   = CASE WHEN OwnerAddress IS NULL THEN NULL
    ELSE LTRIM(RTRIM(PARSENAME(REPLACE(OwnerAddress, ',', '.'), 1))) END;
GO

-- Sample verify
SELECT TOP (100) OwnerAddress, OwnerSplitAddress, OwnerSplitCity, OwnerSplitState
FROM dbo.NashvilleHousing
ORDER BY ParcelID;
GO

/* ======================================================
   5) NORMALIZE SoldAsVacant: map 'Y'/'N' to 'Yes'/'No' (safe CASE)
   ====================================================== */

-- See distribution first
SELECT SoldAsVacant, COUNT(*) AS cnt
FROM dbo.NashvilleHousing
GROUP BY SoldAsVacant
ORDER BY cnt DESC;
GO

BEGIN TRAN;
UPDATE dbo.NashvilleHousing
SET SoldAsVacant = CASE
        WHEN LTRIM(RTRIM(UPPER(SoldAsVacant))) = 'Y' THEN 'Yes'
        WHEN LTRIM(RTRIM(UPPER(SoldAsVacant))) = 'N' THEN 'No'
        ELSE SoldAsVacant  -- leave other values intact
    END;
COMMIT TRAN;
GO

-- Verify normalization
SELECT SoldAsVacant, COUNT(*) AS cnt
FROM dbo.NashvilleHousing
GROUP BY SoldAsVacant
ORDER BY cnt DESC;
GO

/* ======================================================
   6) IDENTIFY & REMOVE DUPLICATES
   - Keep the lowest (or highest) UniqueID as desired. Below keeps the first (lowest UniqueID).
   - Partitioning columns chosen per your earlier script: ParcelID, PropertyAddress, SalePrice, SaleDate, LegalReference
   ====================================================== */

-- Preview duplicates (rows with row_num > 1)
WITH RowNumCTE AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY ParcelID, PropertyAddress, SalePrice, SaleDate, LegalReference
               ORDER BY UniqueID
           ) AS row_num
    FROM dbo.NashvilleHousing
)
SELECT *
FROM RowNumCTE
WHERE row_num > 1
ORDER BY ParcelID, PropertyAddress;
GO

-- Delete duplicates (UNCOMMENT to execute). The delete keeps row_num = 1.
BEGIN TRAN;
WITH RowNumCTE AS (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY ParcelID, PropertyAddress, SalePrice, SaleDate, LegalReference
               ORDER BY UniqueID
           ) AS row_num
    FROM dbo.NashvilleHousing
)
DELETE FROM RowNumCTE
WHERE row_num > 1;
COMMIT TRAN;
GO

/* ======================================================
   7) DELETE / DROP UNUSED COLUMNS (guarded)
   - Review the list below before executing. Uncomment the ALTER TABLE ... DROP COLUMN when you're ready.
   ====================================================== */

-- Check if columns exist
SELECT
    COL_NAME(object_id, column_id) AS ColumnName,
    *
FROM sys.columns
WHERE object_id = OBJECT_ID('dbo.NashvilleHousing')
ORDER BY ColumnName;
GO

-- Example guard and drop (UNCOMMENT to run). Be sure column names are correct.
--IF COL_LENGTH('dbo.NashvilleHousing', 'OwnerAddress') IS NOT NULL
--BEGIN
--    ALTER TABLE dbo.NashvilleHousing
--    DROP COLUMN OwnerAddress;
--END
--IF COL_LENGTH('dbo.NashvilleHousing', 'TaxDistrict') IS NOT NULL
--BEGIN
--    ALTER TABLE dbo.NashvilleHousing
--    DROP COLUMN TaxDistrict;
--END
--IF COL_LENGTH('dbo.NashvilleHousing', 'PropertyAddress') IS NOT NULL
--BEGIN
--    ALTER TABLE dbo.NashvilleHousing
--    DROP COLUMN PropertyAddress;
--END
--IF COL_LENGTH('dbo.NashvilleHousing', 'SaleDate') IS NOT NULL
--BEGIN
--    ALTER TABLE dbo.NashvilleHousing
--    DROP COLUMN SaleDate;
--END
--GO

/* ======================================================
   8) OPTIONAL: Recreate indexes or add computed columns
   - Consider adding an index on ParcelID or other columns used for joins/filters
   ====================================================== */

-- Example: create index on ParcelID if frequent lookups
--IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.NashvilleHousing') AND name = 'IX_NashvilleHousing_ParcelID')
--BEGIN
--    CREATE NONCLUSTERED INDEX IX_NashvilleHousing_ParcelID ON dbo.NashvilleHousing(ParcelID);
--END
--GO

/* ======================================================
   9) OPTIONAL: Import methods (BULK INSERT / OPENROWSET)
   - These require server config and proper file paths. Provided here as commented examples.
   ====================================================== */

-- BULK INSERT example (uncomment and update path; make sure SQL Server has permission):
--BULK INSERT dbo.NashvilleHousing
--FROM 'C:\Temp\Nashville Housing Data for Data Cleaning Project.csv'
--WITH (
--    FIELDTERMINATOR = ',',
--    ROWTERMINATOR = '\n',
--    FIRSTROW = 2  -- if file has header
--);

-- OPENROWSET example (requires Ad Hoc Distributed Queries and ACE/ODBC drivers):
--SELECT * INTO dbo.NashvilleHousing
--FROM OPENROWSET('Microsoft.ACE.OLEDB.12.0',
--    'Text;Database=C:\Temp\;HDR=YES;FMT=Delimited', 'SELECT * FROM [Nashville Housing Data for Data Cleaning Project.csv]');

GO

/* ======================================================
   10) FINAL QUALITY-CHECKS / REPORTS
   - Rows with NULL critical fields
   - SaleDateConverted nulls (if any)
   ====================================================== */

SELECT COUNT(*) AS TotalRows FROM dbo.NashvilleHousing;

SELECT COUNT(*) AS MissingAddressCount
FROM dbo.NashvilleHousing
WHERE PropertyAddress IS NULL
   AND PropertySplitAddress IS NULL;

SELECT *
FROM dbo.NashvilleHousing
WHERE SaleDateConverted IS NULL
  AND SaleDate IS NOT NULL;  -- rows where conversion failed
GO

PRINT 'Data cleaning script finished. Review logs and samples above.';
