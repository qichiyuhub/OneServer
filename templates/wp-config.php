<?php
/**
 * SPDX-License-Identifier: MIT
 * OneServer 生成的 WordPress 最小配置。
 *
 * 这是一份原创的互操作配置模板，不复制 WordPress 的示例文件。配置常量的
 * 含义见 https://developer.wordpress.org/apis/wp-config-php/ 。
 */

// 数据库连接。
define( 'DB_NAME', '%%DB_NAME%%' );
define( 'DB_USER', '%%DB_USER%%' );
define( 'DB_PASSWORD', '%%DB_PASSWORD%%' );
define( 'DB_HOST', '%%DB_HOST%%' );
define( 'DB_CHARSET', '%%DB_CHARSET%%' );
define( 'DB_COLLATE', '%%DB_COLLATE%%' );

/**
 * 密钥由本机生成，不依赖远端随机数服务；它们只需足够随机并保持稳定。
 */
%%SALTS%%

// 同一数据库中各站点必须使用不同前缀。
$table_prefix = '%%TABLE_PREFIX%%';

define( 'WP_DEBUG', false );

// 用户选择的附加配置在生成时插入这里。
%%EXTRA%%

if ( ! defined( 'ABSPATH' ) ) {
    define( 'ABSPATH', __DIR__ . '/' );
}

require_once ABSPATH . 'wp-settings.php';
