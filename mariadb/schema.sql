CREATE TABLE IF NOT EXISTS `blocks` (
  `number` INT UNSIGNED NOT NULL,
  `timestamp` BIGINT UNSIGNED NOT NULL,
  `miner` BINARY(20) NOT NULL,
  `difficulty` VARCHAR(78) NOT NULL,
  `gasused` BIGINT UNSIGNED NOT NULL,
  `gaslimit` BIGINT UNSIGNED NOT NULL,
  `extradata` VARBINARY(32) NOT NULL,
  `parenthash` BINARY(32) NOT NULL,
  `sha3uncles` BINARY(32) NOT NULL,
  `stateroot` BINARY(32) NOT NULL,
  `nonce` BINARY(8) NOT NULL,
  `receiptsroot` BINARY(32) NOT NULL,
  `transactionsroot` BINARY(32) NOT NULL,
  `mixhash` BINARY(32) NOT NULL,
  `logsbloom` BLOB NULL,
  `basefee` VARCHAR(78) NULL,
  PRIMARY KEY (`number`)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `transactions` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `blocknumber` INT UNSIGNED NOT NULL,
  `transactionindex` INT UNSIGNED NOT NULL,
  `from` BINARY(20) NOT NULL,
  `to` BINARY(20) NULL,
  `gas` BIGINT UNSIGNED NOT NULL,
  `gasprice` VARCHAR(78) NULL,
  `value` VARCHAR(78) NOT NULL,
  `nonce` BIGINT UNSIGNED NOT NULL,
  `input` MEDIUMBLOB NULL,
  `maxfeepergas` VARCHAR(78) NULL,
  `maxpriorityfeepergas` VARCHAR(78) NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `block_tx` (`blocknumber`, `transactionindex`)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `transactions_accesslist` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `blocknumber` INT UNSIGNED NOT NULL,
  `transactionindex` INT UNSIGNED NOT NULL,
  `accesslistindex` INT UNSIGNED NOT NULL,
  `address` BINARY(20) NOT NULL,
  `storagekeys` BINARY(32) NULL,
  PRIMARY KEY (`id`),
  KEY `block_tx_access` (`blocknumber`, `transactionindex`, `accesslistindex`)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS `uncles` (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `blocknumber` INT UNSIGNED NOT NULL,
  `uncleheight` INT UNSIGNED NOT NULL,
  `uncleposition` INT UNSIGNED NOT NULL,
  `miner` BINARY(20) NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `block_uncle` (`blocknumber`, `uncleposition`)
) ENGINE=InnoDB;
