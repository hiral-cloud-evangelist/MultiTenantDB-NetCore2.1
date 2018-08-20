﻿using System;
using System.Collections.Generic;
using System.Data;
using System.Data.SqlClient;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using Events_Tenant.Common.Interfaces;
using Events_TenantUserApp.EF.TenantsDdEF6;
using Microsoft.Azure.SqlDatabase.ElasticScale.ShardManagement;

namespace Events_Tenant.Common.Utilities
{

    /// <summary>
    /// The Utilities class for doing common methods
    /// </summary>
    /// <seealso cref="Events_Tenant.Common.Interfaces.IUtilities" />
    public class Utilities : IUtilities
    {
        #region Public methods

        /// <summary>
        /// Register tenant shard
        /// </summary>
        /// <param name="tenantServerConfig">The tenant server configuration.</param>
        /// <param name="databaseConfig">The database configuration.</param>
        /// <param name="catalogConfig">The catalog configuration.</param>
        /// <param name="resetEventDate">If set to true, the events dates for all tenants will be reset </param>
        public async void RegisterTenantShard(TenantServerConfig tenantServerConfig, DatabaseConfig databaseConfig, CatalogConfig catalogConfig, bool resetEventDate)
        {
            //get all database in devtenantserver
            var tenants = GetAllTenantNames(tenantServerConfig, databaseConfig);

            var connectionString = new SqlConnectionStringBuilder
            {
                UserID = databaseConfig.DatabaseUser,
                Password = databaseConfig.DatabasePassword,
                ApplicationName = "EntityFramework",
                ConnectTimeout = databaseConfig.ConnectionTimeOut
            };

            Shard shard = Sharding.CreateNewShard(tenantServerConfig.TenantDatabase, tenantServerConfig.TenantServer, databaseConfig.DatabaseServerPort, catalogConfig.ServicePlan);

            foreach (var tenant in tenants)
            {
                var tenantId = GetTenantKey(tenant);
                var result = await Sharding.RegisterNewShard(tenantId, catalogConfig.ServicePlan, shard);
                if (result)
                {
                    // resets all tenants' event dates
                    if (resetEventDate)
                    {
                        #region EF6
                        //use EF6 since execution of Stored Procedure in EF Core for anonymous return type is not supported yet
                        using (var context = new TenantContext(Sharding.ShardMap, tenantId, connectionString.ConnectionString))
                        {
                            //context.Database.ExecuteSqlCommand("sp_ResetEventDates");
                        }
                        #endregion

                        #region EF core
                        //https://github.com/aspnet/EntityFramework/issues/7032
                        //using (var context = new TenantDbContext(Sharding.ShardMap, tenantId, connectionString))
                        //{
                        //    context.Database.ExecuteSqlCommand("sp_ResetEventDates");
                        //}
                        #endregion
                    }
                }
            }
        }

        /// <summary>
        /// Converts the int key to bytes array.
        /// </summary>
        /// <param name="key">The key.</param>
        /// <returns></returns>
        public byte[] ConvertIntKeyToBytesArray(int key)
        {
            byte[] normalized = BitConverter.GetBytes(IPAddress.HostToNetworkOrder(key));

            // Maps Int32.Min - Int32.Max to UInt32.Min - UInt32.Max.
            normalized[0] ^= 0x80;

            return normalized;
        }

        #endregion

        #region Private methods

        /// <summary>
        /// Gets all tenant names from tenant server
        /// </summary>
        /// <param name="tenantServerConfig">The tenant server configuration.</param>
        /// <param name="databaseConfig">The database configuration.</param>
        /// <returns></returns>
        private List<string> GetAllTenantNames(TenantServerConfig tenantServerConfig, DatabaseConfig databaseConfig)
        {
            List<string> list = new List<string>();

            string conString = $"Server=Tcp:{tenantServerConfig.TenantServer},{databaseConfig.DatabaseServerPort};Database={tenantServerConfig.TenantDatabase};User ID={databaseConfig.DatabaseUser};Password={databaseConfig.DatabasePassword};Trusted_Connection=False;Encrypt=True;Connection Timeout={databaseConfig.ConnectionTimeOut};";

            using (SqlConnection con = new SqlConnection(conString))
            {
                con.Open();

                using (SqlCommand cmd = new SqlCommand("SELECT VenueName from Venues", con))
                {
                    using (IDataReader dr = cmd.ExecuteReader())
                    {
                        while (dr.Read())
                        {
                            list.Add(dr[0].ToString().ToLower().Replace(" ", ""));
                        }
                    }
                }
            }
            return list;
        }

        /// <summary>
        /// Generates the tenant Id using MD5 Hashing.
        /// </summary>
        /// <param name="tenantName">Name of the tenant.</param>
        /// <returns></returns>
        private int GetTenantKey(string tenantName)
        {
            var normalizedTenantName = tenantName.Replace(" ", string.Empty).ToLower();

            //Produce utf8 encoding of tenant name 
            var tenantNameBytes = Encoding.UTF8.GetBytes(normalizedTenantName);

            //Produce the md5 hash which reduces the size
            MD5 md5 = MD5.Create();
            var tenantHashBytes = md5.ComputeHash(tenantNameBytes);

            //Convert to integer for use as the key in the catalog 
            int tenantKey = BitConverter.ToInt32(tenantHashBytes, 0);

            return tenantKey;
        }
        #endregion
    }
}
