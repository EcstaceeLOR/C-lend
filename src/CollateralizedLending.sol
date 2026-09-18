// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Like {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function decimals() external view returns (uint8);
}

interface IPriceOracle {
    function getPrice(address asset) external view returns (uint256 price, uint256 updatedAt);
}

/// @title CollateralizedLending
/// @notice A compact collateralized lending market with time-based simple interest,
///         oracle-validated risk checks, and bounded liquidations.
contract CollateralizedLending {
    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;
    uint256 public constant YEAR = 365 days;
    uint256 public constant CLOSE_FACTOR_BPS = 5_000;

    error NotOwner();
    error ZeroAddress();
    error ZeroAmount();
    error InvalidConfig();
    error InvalidDecimals();
    error UnsupportedAsset(address asset);
    error CollateralNotEnabled(address asset);
    error BorrowNotEnabled(address asset);
    error MissingPrice(address asset);
    error StalePrice(address asset);
    error InsufficientLiquidity();
    error InsufficientCollateral();
    error BorrowLimitExceeded(uint256 debtUsd, uint256 borrowLimitUsd);
    error UnhealthyAccount();
    error HealthyAccount();
    error LiquidationTooSmall();
    error TransferFailed();
    error Reentrancy();

    struct AssetConfig {
        bool supported;
        bool collateralEnabled;
        bool borrowEnabled;
        uint8 decimals;
        uint16 collateralFactorBps;
        uint16 liquidationThresholdBps;
        uint16 liquidationBonusBps;
        uint16 interestRateBps;
        uint40 maxPriceAge;
    }

    struct DebtPosition {
        uint256 principal;
        uint256 accruedInterest;
        uint256 lastAccrued;
    }

    address public owner;
    IPriceOracle public oracle;

    mapping(address asset => AssetConfig) public assetConfigs;
    address[] public assets;

    mapping(address user => mapping(address asset => uint256)) public collateralBalance;
    mapping(address user => mapping(address asset => DebtPosition)) internal _debts;

    uint256 private _locked = 1;

    event OwnershipTransferred(address indexed oldOwner, address indexed newOwner);
    event OracleUpdated(address indexed oldOracle, address indexed newOracle);
    event AssetConfigured(
        address indexed asset,
        bool collateralEnabled,
        bool borrowEnabled,
        uint16 collateralFactorBps,
        uint16 liquidationThresholdBps,
        uint16 liquidationBonusBps,
        uint16 interestRateBps,
        uint40 maxPriceAge
    );
    event CollateralDeposited(address indexed user, address indexed asset, uint256 amount);
    event Borrowed(address indexed user, address indexed asset, uint256 amount);
    event Repaid(
        address indexed payer,
        address indexed borrower,
        address indexed asset,
        uint256 amount,
        uint256 principalPaid,
        uint256 interestPaid
    );
    event Liquidated(
        address indexed liquidator,
        address indexed borrower,
        address indexed debtAsset,
        address collateralAsset,
        uint256 repaidAmount,
        uint256 collateralSeized,
        uint256 bonusBps
    );
    event CollateralWithdrawn(address indexed user, address indexed asset, uint256 amount);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    constructor(address oracle_) {
        if (oracle_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        oracle = IPriceOracle(oracle_);
        emit OwnershipTransferred(address(0), msg.sender);
        emit OracleUpdated(address(0), oracle_);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function setOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert ZeroAddress();
        address oldOracle = address(oracle);
        oracle = IPriceOracle(newOracle);
        emit OracleUpdated(oldOracle, newOracle);
    }

    function configureAsset(
        address asset,
        bool collateralEnabled,
        bool borrowEnabled,
        uint16 collateralFactorBps,
        uint16 liquidationThresholdBps,
        uint16 liquidationBonusBps,
        uint16 interestRateBps,
        uint40 maxPriceAge
    ) external onlyOwner {
        if (asset == address(0)) revert ZeroAddress();
        if (!collateralEnabled && !borrowEnabled) revert InvalidConfig();
        if (maxPriceAge == 0) revert InvalidConfig();
        if (collateralFactorBps > liquidationThresholdBps || liquidationThresholdBps > BPS) revert InvalidConfig();
        if (liquidationBonusBps > 2_000 || interestRateBps > BPS) revert InvalidConfig();
        if (!collateralEnabled && (collateralFactorBps != 0 || liquidationThresholdBps != 0 || liquidationBonusBps != 0)) {
            revert InvalidConfig();
        }

        uint8 tokenDecimals = IERC20Like(asset).decimals();
        if (tokenDecimals > 18) revert InvalidDecimals();

        AssetConfig storage cfg = assetConfigs[asset];
        if (!cfg.supported) assets.push(asset);

        cfg.supported = true;
        cfg.collateralEnabled = collateralEnabled;
        cfg.borrowEnabled = borrowEnabled;
        cfg.decimals = tokenDecimals;
        cfg.collateralFactorBps = collateralFactorBps;
        cfg.liquidationThresholdBps = liquidationThresholdBps;
        cfg.liquidationBonusBps = liquidationBonusBps;
        cfg.interestRateBps = interestRateBps;
        cfg.maxPriceAge = maxPriceAge;

        emit AssetConfigured(
            asset,
            collateralEnabled,
            borrowEnabled,
            collateralFactorBps,
            liquidationThresholdBps,
            liquidationBonusBps,
            interestRateBps,
            maxPriceAge
        );
    }

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    function depositCollateral(address asset, uint256 amount) external nonReentrant {
        AssetConfig memory cfg = _requireSupported(asset);
        if (!cfg.collateralEnabled) revert CollateralNotEnabled(asset);
        if (amount == 0) revert ZeroAmount();

        _pullToken(asset, msg.sender, amount);
        collateralBalance[msg.sender][asset] += amount;

        emit CollateralDeposited(msg.sender, asset, amount);
    }

    function borrow(address asset, uint256 amount) external nonReentrant {
        AssetConfig memory cfg = _requireSupported(asset);
        if (!cfg.borrowEnabled) revert BorrowNotEnabled(asset);
        if (amount == 0) revert ZeroAmount();
        if (IERC20Like(asset).balanceOf(address(this)) < amount) revert InsufficientLiquidity();

        _accrueAll(msg.sender);

        uint256 limitUsd = _borrowLimitUsd(msg.sender);
        uint256 currentDebtUsd = _storedDebtUsd(msg.sender);
        uint256 requestedUsd = _toUsd(asset, amount);
        uint256 newDebtUsd = currentDebtUsd + requestedUsd;
        if (newDebtUsd > limitUsd) revert BorrowLimitExceeded(newDebtUsd, limitUsd);

        DebtPosition storage position = _debts[msg.sender][asset];
        if (position.lastAccrued == 0) position.lastAccrued = block.timestamp;
        position.principal += amount;

        _pushToken(asset, msg.sender, amount);
        emit Borrowed(msg.sender, asset, amount);
    }

    function repay(address asset, uint256 amount) external nonReentrant returns (uint256 repaid) {
        return _repayFor(msg.sender, msg.sender, asset, amount);
    }

    function repayFor(address borrower, address asset, uint256 amount) external nonReentrant returns (uint256 repaid) {
        return _repayFor(msg.sender, borrower, asset, amount);
    }

    function withdrawCollateral(address asset, uint256 amount) external nonReentrant {
        AssetConfig memory cfg = _requireSupported(asset);
        if (!cfg.collateralEnabled) revert CollateralNotEnabled(asset);
        if (amount == 0) revert ZeroAmount();
        if (collateralBalance[msg.sender][asset] < amount) revert InsufficientCollateral();

        _accrueAll(msg.sender);
        collateralBalance[msg.sender][asset] -= amount;

        if (!_isHealthyStored(msg.sender)) revert UnhealthyAccount();

        _pushToken(asset, msg.sender, amount);
        emit CollateralWithdrawn(msg.sender, asset, amount);
    }

    function liquidate(
        address borrower,
        address debtAsset,
        address collateralAsset,
        uint256 requestedRepay
    ) external nonReentrant returns (uint256 actualRepay, uint256 collateralSeized) {
        AssetConfig memory debtCfg = _requireSupported(debtAsset);
        AssetConfig memory collateralCfg = _requireSupported(collateralAsset);
        if (!debtCfg.borrowEnabled) revert BorrowNotEnabled(debtAsset);
        if (!collateralCfg.collateralEnabled) revert CollateralNotEnabled(collateralAsset);
        if (requestedRepay == 0) revert ZeroAmount();

        _accrueAll(borrower);
        if (_isHealthyStored(borrower)) revert HealthyAccount();

        DebtPosition storage position = _debts[borrower][debtAsset];
        uint256 debt = position.principal + position.accruedInterest;
        uint256 collateralAvailable = collateralBalance[borrower][collateralAsset];
        if (debt == 0 || collateralAvailable == 0) revert LiquidationTooSmall();

        uint256 maxClose = (debt * CLOSE_FACTOR_BPS) / BPS;
        if (maxClose == 0) maxClose = debt;

        uint256 collateralUsd = _toUsd(collateralAsset, collateralAvailable);
        uint256 maxRepayUsdByCollateral = (collateralUsd * BPS) / (BPS + collateralCfg.liquidationBonusBps);
        uint256 maxRepayByCollateral = _fromUsd(debtAsset, maxRepayUsdByCollateral);

        actualRepay = _min(requestedRepay, debt);
        actualRepay = _min(actualRepay, maxClose);
        actualRepay = _min(actualRepay, maxRepayByCollateral);
        if (actualRepay == 0) revert LiquidationTooSmall();

        uint256 repayUsd = _toUsd(debtAsset, actualRepay);
        uint256 seizeUsd = (repayUsd * (BPS + collateralCfg.liquidationBonusBps)) / BPS;
        collateralSeized = _fromUsd(collateralAsset, seizeUsd);

        if (actualRepay == maxRepayByCollateral || collateralSeized > collateralAvailable) {
            collateralSeized = collateralAvailable;
        }

        _pullToken(debtAsset, msg.sender, actualRepay);
        _reduceDebt(position, actualRepay);

        collateralBalance[borrower][collateralAsset] = collateralAvailable - collateralSeized;
        _pushToken(collateralAsset, msg.sender, collateralSeized);

        emit Liquidated(
            msg.sender,
            borrower,
            debtAsset,
            collateralAsset,
            actualRepay,
            collateralSeized,
            collateralCfg.liquidationBonusBps
        );
    }

    function debtOf(address user, address asset)
        public
        view
        returns (uint256 principal, uint256 interest, uint256 total)
    {
        DebtPosition memory position = _debts[user][asset];
        principal = position.principal;
        interest = position.accruedInterest + _pendingInterest(asset, position);
        total = principal + interest;
    }

    function borrowLimitUsd(address user) external view returns (uint256) {
        return _borrowLimitUsd(user);
    }

    function totalDebtUsd(address user) external view returns (uint256) {
        return _debtUsdView(user);
    }

    function healthFactor(address user) external view returns (uint256) {
        uint256 debtUsd = _debtUsdView(user);
        if (debtUsd == 0) return type(uint256).max;
        return (_liquidationCapacityUsd(user) * WAD) / debtUsd;
    }

    function hasBadDebt(address user) external view returns (bool) {
        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            AssetConfig memory cfg = assetConfigs[assets[i]];
            if (cfg.collateralEnabled && collateralBalance[user][assets[i]] != 0) return false;
        }
        for (uint256 i; i < length; ++i) {
            AssetConfig memory cfg = assetConfigs[assets[i]];
            if (!cfg.borrowEnabled) continue;
            (, , uint256 total) = debtOf(user, assets[i]);
            if (total != 0) return true;
        }
        return false;
    }

    function _repayFor(address payer, address borrower, address asset, uint256 amount)
        internal
        returns (uint256 repaid)
    {
        AssetConfig memory cfg = _requireSupported(asset);
        if (!cfg.borrowEnabled) revert BorrowNotEnabled(asset);
        if (amount == 0) revert ZeroAmount();

        _accrue(borrower, asset);
        DebtPosition storage position = _debts[borrower][asset];
        uint256 total = position.principal + position.accruedInterest;
        if (total == 0) revert ZeroAmount();

        repaid = amount < total ? amount : total;
        _pullToken(asset, payer, repaid);

        (uint256 principalPaid, uint256 interestPaid) = _reduceDebt(position, repaid);
        emit Repaid(payer, borrower, asset, repaid, principalPaid, interestPaid);
    }

    function _reduceDebt(DebtPosition storage position, uint256 amount)
        internal
        returns (uint256 principalPaid, uint256 interestPaid)
    {
        interestPaid = amount < position.accruedInterest ? amount : position.accruedInterest;
        position.accruedInterest -= interestPaid;

        uint256 remaining = amount - interestPaid;
        principalPaid = remaining < position.principal ? remaining : position.principal;
        position.principal -= principalPaid;

        if (position.principal == 0 && position.accruedInterest == 0) {
            position.lastAccrued = 0;
        }
    }

    function _accrueAll(address user) internal {
        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            if (assetConfigs[assets[i]].borrowEnabled) _accrue(user, assets[i]);
        }
    }

    function _accrue(address user, address asset) internal {
        DebtPosition storage position = _debts[user][asset];
        if (position.principal == 0) {
            if (position.lastAccrued != 0) position.lastAccrued = block.timestamp;
            return;
        }
        if (position.lastAccrued == 0) {
            position.lastAccrued = block.timestamp;
            return;
        }

        uint256 elapsed = block.timestamp - position.lastAccrued;
        if (elapsed == 0) return;

        uint256 rateBps = assetConfigs[asset].interestRateBps;
        uint256 interest = (position.principal * rateBps * elapsed) / BPS / YEAR;
        position.accruedInterest += interest;
        position.lastAccrued = block.timestamp;
    }

    function _pendingInterest(address asset, DebtPosition memory position) internal view returns (uint256) {
        if (position.principal == 0 || position.lastAccrued == 0 || block.timestamp <= position.lastAccrued) return 0;
        uint256 elapsed = block.timestamp - position.lastAccrued;
        return (position.principal * assetConfigs[asset].interestRateBps * elapsed) / BPS / YEAR;
    }

    function _borrowLimitUsd(address user) internal view returns (uint256 limitUsd) {
        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            address asset = assets[i];
            AssetConfig memory cfg = assetConfigs[asset];
            uint256 amount = collateralBalance[user][asset];
            if (!cfg.collateralEnabled || amount == 0) continue;
            limitUsd += (_toUsd(asset, amount) * cfg.collateralFactorBps) / BPS;
        }
    }

    function _liquidationCapacityUsd(address user) internal view returns (uint256 capacityUsd) {
        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            address asset = assets[i];
            AssetConfig memory cfg = assetConfigs[asset];
            uint256 amount = collateralBalance[user][asset];
            if (!cfg.collateralEnabled || amount == 0) continue;
            capacityUsd += (_toUsd(asset, amount) * cfg.liquidationThresholdBps) / BPS;
        }
    }

    function _storedDebtUsd(address user) internal view returns (uint256 debtUsd) {
        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            address asset = assets[i];
            AssetConfig memory cfg = assetConfigs[asset];
            if (!cfg.borrowEnabled) continue;
            DebtPosition memory position = _debts[user][asset];
            uint256 total = position.principal + position.accruedInterest;
            if (total == 0) continue;
            debtUsd += _toUsd(asset, total);
        }
    }

    function _debtUsdView(address user) internal view returns (uint256 debtUsd) {
        uint256 length = assets.length;
        for (uint256 i; i < length; ++i) {
            address asset = assets[i];
            AssetConfig memory cfg = assetConfigs[asset];
            if (!cfg.borrowEnabled) continue;
            (, , uint256 total) = debtOf(user, asset);
            if (total == 0) continue;
            debtUsd += _toUsd(asset, total);
        }
    }

    function _isHealthyStored(address user) internal view returns (bool) {
        uint256 debtUsd = _storedDebtUsd(user);
        if (debtUsd == 0) return true;
        return _liquidationCapacityUsd(user) >= debtUsd;
    }

    function _toUsd(address asset, uint256 amount) internal view returns (uint256) {
        AssetConfig memory cfg = _requireSupported(asset);
        (uint256 price,) = _validatedPrice(asset, cfg);
        return (amount * price) / (10 ** cfg.decimals);
    }

    function _fromUsd(address asset, uint256 usdValue) internal view returns (uint256) {
        AssetConfig memory cfg = _requireSupported(asset);
        (uint256 price,) = _validatedPrice(asset, cfg);
        return (usdValue * (10 ** cfg.decimals)) / price;
    }

    function _validatedPrice(address asset, AssetConfig memory cfg)
        internal
        view
        returns (uint256 price, uint256 updatedAt)
    {
        (price, updatedAt) = oracle.getPrice(asset);
        if (price == 0 || updatedAt == 0) revert MissingPrice(asset);
        if (updatedAt > block.timestamp || block.timestamp - updatedAt > cfg.maxPriceAge) revert StalePrice(asset);
    }

    function _requireSupported(address asset) internal view returns (AssetConfig memory cfg) {
        cfg = assetConfigs[asset];
        if (!cfg.supported) revert UnsupportedAsset(asset);
    }

    function _pullToken(address token, address from, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20Like.transferFrom.selector, from, address(this), amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _pushToken(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSelector(IERC20Like.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
