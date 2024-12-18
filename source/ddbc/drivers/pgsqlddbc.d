/**
 * DDBC - D DataBase Connector - abstraction layer for RDBMS access, with interface similar to JDBC.
 *
 * Source file ddbc/drivers/pgsqlddbc.d.
 *
 * DDBC library attempts to provide implementation independent interface to different databases.
 *
 * Set of supported RDBMSs can be extended by writing Drivers for particular DBs.
 * Currently it only includes MySQL driver.
 *
 * JDBC documentation can be found here:
 * $(LINK http://docs.oracle.com/javase/1.5.0/docs/api/java/sql/package-summary.html)$(BR)
 *
 * This module contains implementation of PostgreSQL Driver
 *
 *
 * You can find usage examples in unittest{} sections.
 *
 * Copyright: Copyright 2013
 * License:   $(LINK www.boost.org/LICENSE_1_0.txt, Boost License 1.0).
 * Author:   Vadim Lopatin
 */
module ddbc.drivers.pgsqlddbc;


version(USE_PGSQL) {
    pragma(msg, "DDBC will use PGSQL driver");

    import std.algorithm;
    import std.conv;
    import std.datetime : Date, DateTime, TimeOfDay;
    import std.datetime.date;
    import std.datetime.systime;
    import std.exception : enforce;
    static if (__traits(compiles, (){ import std.logger; } )) {
        import std.logger;
    } else {
        import std.experimental.logger;
    }
    import std.stdio;
    import std.string;
    import std.variant;
    import std.array;
    import core.sync.mutex;

    import ddbc.common;
    import ddbc.core;
    import derelict.pq.pq;
    //import ddbc.drivers.pgsql;
    import ddbc.drivers.utils;

    // Postgresql Object ID types, which can be checked for query result columns.
    // See: https://github.com/postgres/postgres/blob/master/src/include/catalog/pg_type.dat
    const int BOOLOID = 16;
    const int BYTEAOID = 17;
    const int CHAROID = 18;
    const int NAMEOID = 19;
    const int INT8OID = 20;
    const int INT2OID = 21;
    const int INT2VECTOROID = 22;
    const int INT4OID = 23;
    const int REGPROCOID = 24;
    const int TEXTOID = 25;
    const int OIDOID = 26;
    const int TIDOID = 27;
    const int XIDOID = 28;
    const int CIDOID = 29;
    const int OIDVECTOROID = 30;
    const int JSONOID = 114;
    const int JSONBOID = 3802;
    const int XMLOID = 142;
    const int PGNODETREEOID = 194;
    const int POINTOID = 600;
    const int LSEGOID = 601;
    const int PATHOID = 602;
    const int BOXOID = 603;
    const int POLYGONOID = 604;
    const int LINEOID = 628;
    const int FLOAT4OID = 700;
    const int FLOAT8OID = 701;
    const int ABSTIMEOID = 702;
    const int RELTIMEOID = 703;
    const int TINTERVALOID = 704;
    const int UNKNOWNOID = 705;
    const int CIRCLEOID = 718;
    const int CASHOID = 790;
    const int MACADDROID = 829;
    const int INETOID = 869;
    const int CIDROID = 650;
    const int INT4ARRAYOID = 1007;
    const int TEXTARRAYOID = 1009;
    const int FLOAT4ARRAYOID = 1021;
    const int ACLITEMOID = 1033;
    const int CSTRINGARRAYOID = 1263;
    const int BPCHAROID = 1042;
    const int VARCHAROID = 1043;
    const int DATEOID = 1082;
    const int TIMEOID = 1083;
    const int TIMESTAMPOID = 1114;
    const int TIMESTAMPTZOID = 1184;
    const int INTERVALOID = 1186;
    const int TIMETZOID = 1266;
    const int BITOID = 1560;
    const int VARBITOID = 1562;
    const int NUMERICOID = 1700;
    const int REFCURSOROID = 1790;
    const int REGPROCEDUREOID = 2202;
    const int REGOPEROID = 2203;
    const int REGOPERATOROID = 2204;
    const int REGCLASSOID = 2205;
    const int REGTYPEOID = 2206;
    const int REGTYPEARRAYOID = 2211;
    const int UUIDOID = 2950;
    const int TSVECTOROID = 3614;
    const int GTSVECTOROID = 3642;
    const int TSQUERYOID = 3615;
    const int REGCONFIGOID = 3734;
    const int REGDICTIONARYOID = 3769;
    const int INT4RANGEOID = 3904;
    const int RECORDOID = 2249;
    const int RECORDARRAYOID = 2287;
    const int CSTRINGOID = 2275;
    const int ANYOID = 2276;
    const int ANYARRAYOID = 2277;
    const int VOIDOID = 2278;
    const int TRIGGEROID = 2279;
    const int EVTTRIGGEROID = 3838;
    const int LANGUAGE_HANDLEROID = 2280;
    const int INTERNALOID = 2281;
    const int OPAQUEOID = 2282;
    const int ANYELEMENTOID = 2283;
    const int ANYNONARRAYOID = 2776;
    const int ANYENUMOID = 3500;
    const int FDW_HANDLEROID = 3115;
    const int ANYRANGEOID = 3831;

    string bytesToBytea(byte[] bytes) {
        return ubytesToBytea(cast(ubyte[])bytes);
    }

    string ubytesToBytea(ubyte[] bytes) {
        if (bytes is null || !bytes.length)
            return null;
        char[] res;
        res.assumeSafeAppend;
        res ~= "\\x";
        immutable static char[16] hex_digits = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'A', 'B', 'C', 'D', 'E', 'F'];
        foreach(b; bytes) {
            res ~= hex_digits[(b >> 4) & 0x0F];
            res ~= hex_digits[b & 0x0F];
        }
        return cast(string)res;
    }

    byte[] byteaToBytes(string s) {
        return cast(byte[])byteaToUbytes(s);
    }

    private static int fromHexDigit(char ch, int defValue = -1) {
        if (ch >= '0' && ch <= '9')
            return ch - '0';
        if (ch >= 'A' && ch <= 'F')
            return ch - 'A' + 10;
        if (ch >= 'a' && ch <= 'f')
            return ch - 'a' + 10;
        return defValue;
    }
    ubyte[] byteaToUbytes(string s) {
        if (s is null || !s.length)
            return null;
        ubyte[] res;
        if (s.length > 2 && s[0] == '\\' && s[1] == 'x') {
            // hex string format
            for (int i = 2; i + 1 < s.length; i += 2) {
                int d1 = fromHexDigit(s[i], 0);
                int d2 = fromHexDigit(s[i + 1], 0);
                res ~= cast(ubyte)((d1 << 4) | (d2));
            }
        } else {
            // escaped string format
            bool lastBackSlash = 0;
            foreach(ch; s) {
                if (ch == '\\') {
                    if (lastBackSlash) {
                        res ~= '\\';
                        lastBackSlash = false;
                    } else {
                        lastBackSlash = true;
                    }
                } else {
                    if (lastBackSlash) {
                        if (ch == '0') {
                            res ~= 0;
                        } else if (ch == 'r') {
                            res ~= '\r';
                        } else if (ch == 'n') {
                            res ~= '\n';
                        } else if (ch == 't') {
                            res ~= '\t';
                        } else {
                        }
                    } else {
                        res ~= cast(byte)ch;
                    }
                    lastBackSlash = false;
                }
            }
        }
        return res;
    }

    class PGSQLConnection : ddbc.core.Connection {
    private:
    	string url;
    	string[string] params;
    	string dbName;
    	string username;
    	string password;
    	string hostname;
    	int port = 5432;
    	PGconn * conn;
    	bool closed;
		bool autocommit = true;
        bool useSsl = true;
    	Mutex mutex;


    	PGSQLStatement [] activeStatements;

    	void closeUnclosedStatements() {
    		PGSQLStatement [] list = activeStatements.dup;
    		foreach(stmt; list) {
    			stmt.close();
    		}
    	}

        void onStatementClosed(PGSQLStatement stmt) {
            myRemove(activeStatements, stmt);
        }

    	void checkClosed() {
    		if (closed)
    			throw new SQLException("Connection is already closed");
    	}

    public:

    	// db connections are DialectAware
		override DialectType getDialectType() {
			return DialectType.PGSQL;
		}

    	void lock() {
    		mutex.lock();
    	}

    	void unlock() {
    		mutex.unlock();
    	}

    	PGconn * getConnection() { return conn; }


    	this(string url, string[string] params) {
    		mutex = new Mutex();
    		this.url = url;
    		this.params = params;
    		//writeln("parsing url " ~ url);
            extractParamsFromURL(url, this.params);
    		string dbName = "";
    		ptrdiff_t firstSlashes = std.string.indexOf(url, "//");
    		ptrdiff_t lastSlash = std.string.lastIndexOf(url, '/');
    		ptrdiff_t hostNameStart = firstSlashes >= 0 ? firstSlashes + 2 : 0;
    		ptrdiff_t hostNameEnd = lastSlash >=0 && lastSlash > firstSlashes + 1 ? lastSlash : url.length;
    		if (hostNameEnd < url.length - 1) {
    			dbName = url[hostNameEnd + 1 .. $];
    		}
    		hostname = url[hostNameStart..hostNameEnd];
    		if (hostname.length == 0)
    			hostname = "localhost";
    		ptrdiff_t portDelimiter = std.string.indexOf(hostname, ":");
    		if (portDelimiter >= 0) {
    			string portString = hostname[portDelimiter + 1 .. $];
    			hostname = hostname[0 .. portDelimiter];
    			if (portString.length > 0)
    				port = to!int(portString);
    			if (port < 1 || port > 65535)
    				port = 5432;
    		}
            if ("user" in this.params)
    		    username = this.params["user"];
            if ("password" in this.params)
    		    password = this.params["password"];
            if ("ssl" in this.params)
                useSsl = (this.params["ssl"] == "true");


    		//writeln("host " ~ hostname ~ " : " ~ to!string(port) ~ " db=" ~ dbName ~ " user=" ~ username ~ " pass=" ~ password);
            // TODO: support SSL param

    		const char ** keywords = [std.string.toStringz("host"), std.string.toStringz("port"), std.string.toStringz("dbname"), std.string.toStringz("user"), std.string.toStringz("password"), null].ptr;
    		const char ** values = [std.string.toStringz(hostname), std.string.toStringz(to!string(port)), std.string.toStringz(dbName), std.string.toStringz(username), std.string.toStringz(password), null].ptr;
    		//writeln("trying to connect");
    		conn = PQconnectdbParams(keywords, values, 0);
    		if(conn is null)
    			throw new SQLException("Cannot get Postgres connection");
    		if(PQstatus(conn) != CONNECTION_OK)
    			throw new SQLException(copyCString(PQerrorMessage(conn)));
    		closed = false;
    		setAutoCommit(true);
    		updateConnectionParams();
    	}

    	void updateConnectionParams() {
    		Statement stmt = createStatement();
    		scope(exit) stmt.close();
    		stmt.executeUpdate("SET NAMES 'utf8'");
    	}

    	override void close() {
    		checkClosed();

    		lock();
    		scope(exit) unlock();

    		closeUnclosedStatements();

    		PQfinish(conn);
    		closed = true;
    	}

    	override void commit() {
    		checkClosed();

    		lock();
    		scope(exit) unlock();

    		Statement stmt = createStatement();
    		scope(exit) stmt.close();
    		stmt.executeUpdate("COMMIT");
            if (!autocommit) {
                Statement stmt2 = createStatement();
                scope(exit) stmt2.close();
                stmt2.executeUpdate("BEGIN");
            }
    	}

    	override Statement createStatement() {
    		checkClosed();

    		lock();
    		scope(exit) unlock();

    		PGSQLStatement stmt = new PGSQLStatement(this);
    		activeStatements ~= stmt;
    		return stmt;
    	}

    	PreparedStatement prepareStatement(string sql) {
    		checkClosed();

    		lock();
    		scope(exit) unlock();

    		PGSQLPreparedStatement stmt = new PGSQLPreparedStatement(this, sql);
    		activeStatements ~= stmt;
    		return stmt;
    	}

    	override string getCatalog() {
    		return dbName;
    	}

    	/// Sets the given catalog name in order to select a subspace of this Connection object's database in which to work.
    	override void setCatalog(string catalog) {
    		checkClosed();
    		if (dbName == catalog)
    			return;

    		lock();
    		scope(exit) unlock();

    		//conn.selectDB(catalog);
    		dbName = catalog;
    		// TODO:

    		throw new SQLException("Not implemented");
    	}

    	override bool isClosed() {
    		return closed;
    	}

    	override void rollback() {
    		checkClosed();

    		lock();
    		scope(exit) unlock();

    		Statement stmt = createStatement();
    		scope(exit) stmt.close();
    		stmt.executeUpdate("ROLLBACK");
            if (!autocommit) {
                stmt.executeUpdate("BEGIN");
            }
    	}
    	override bool getAutoCommit() {
    		return autocommit;
    	}
    	override void setAutoCommit(bool autoCommit) {
    		checkClosed();
    		if (this.autocommit == autoCommit)
    			return;
    		lock();
    		scope(exit) unlock();

            try {
                Statement stmt = createStatement();
                scope(exit) stmt.close();
                if (autoCommit) {
                  // If switching on autocommit, commit any ongoing transaction.
                  stmt.executeUpdate("COMMIT");
                } else {
                  // If switching off autocommit, start a transaction.
                  stmt.executeUpdate("BEGIN");
                }
                this.autocommit = autoCommit;
            } catch (Throwable e) {
                throw new SQLException(e);
            }
    	}

        override TransactionIsolation getTransactionIsolation() {
            checkClosed();
            lock();
            scope(exit) unlock();

            try {
                Statement stmt = createStatement();
                scope(exit) stmt.close();
                ddbc.core.ResultSet resultSet = stmt.executeQuery("SHOW TRANSACTION ISOLATION LEVEL");
                if (resultSet.next()) {
                    switch (resultSet.getString(1)) {
                        case "read uncommitted":
                            return TransactionIsolation.READ_UNCOMMITTED;
                        case "repeatable read":
                            return TransactionIsolation.REPEATABLE_READ;
                        case "serializable":
                            return TransactionIsolation.SERIALIZABLE;
                        case "read committed":
                        default:  // Postgresql default
                            return TransactionIsolation.READ_COMMITTED;
                    }
                } else {
                    return TransactionIsolation.READ_COMMITTED;  // Postgresql default
                }
            } catch (Throwable e) {
                throw new SQLException(e);
            }
        }

        override void setTransactionIsolation(TransactionIsolation level) {
            checkClosed();
            lock();
            scope(exit) unlock();

            try {
                Statement stmt = createStatement();
                // See: https://www.postgresql.org/docs/current/sql-set-transaction.html
                string query = "SET TRANSACTION ISOLATION LEVEL ";
                switch (level) {
                    case TransactionIsolation.READ_UNCOMMITTED:
                        query ~= "READ UNCOMMITTED";
                        break;
                    case TransactionIsolation.REPEATABLE_READ:
                        query ~= "REPEATABLE READ";
                        break;
                    case TransactionIsolation.SERIALIZABLE:
                        query ~= "SERIALIZABLE";
                        break;
                    case TransactionIsolation.READ_COMMITTED:
                    default:
                        query ~= "READ COMMITTED";
                        break;
                }
                stmt.executeUpdate(query);
            } catch (Throwable e) {
                throw new SQLException(e);
            }
        }
    }

    class PGSQLStatement : Statement {
    private:
    	PGSQLConnection conn;
    //	Command * cmd;
    //	ddbc.drivers.mysql.ResultSet rs;
    	PGSQLResultSet resultSet;

    	bool closed;

    public:

		// statements are DialectAware
        override DialectType getDialectType() {
            return conn.getDialectType();
        }

    	void checkClosed() {
    		enforce!SQLException(!closed, "Statement is already closed");
    	}

    	void lock() {
    		conn.lock();
    	}

    	void unlock() {
    		conn.unlock();
    	}

    	this(PGSQLConnection conn) {
    		this.conn = conn;
    	}

    	ResultSetMetaData createMetadata(PGresult * res) {
    		int rows = PQntuples(res);
    		int fieldCount = PQnfields(res);
    		ColumnMetadataItem[] list = new ColumnMetadataItem[fieldCount];
    		for(int i = 0; i < fieldCount; i++) {
    			ColumnMetadataItem item = new ColumnMetadataItem();
    			//item.schemaName = field.db;
    			item.name = copyCString(PQfname(res, i));
                //item.tableName = copyCString(PQftable(res, i));
    			int fmt = PQfformat(res, i);
    			ulong t = PQftype(res, i);
    			item.label = copyCString(PQfname(res, i));
    			//item.precision = field.length;
    			//item.scale = field.scale;
    			//item.isNullable = !field.notNull;
    			//item.isSigned = !field.unsigned;
    			//item.type = fromPGSQLType(field.type);
    //			// TODO: fill more params
    			list[i] = item;
    		}
    		return new ResultSetMetaDataImpl(list);
    	}
    	ParameterMetaData createParameterMetadata(int paramCount) {
            ParameterMetaDataItem[] res = new ParameterMetaDataItem[paramCount];
            for(int i = 0; i < paramCount; i++) {
    			ParameterMetaDataItem item = new ParameterMetaDataItem();
    			item.precision = 0;
    			item.scale = 0;
    			item.isNullable = true;
    			item.isSigned = true;
    			item.type = SqlType.VARCHAR;
    			res[i] = item;
    		}
    		return new ParameterMetaDataImpl(res);
    	}
    public:
    	PGSQLConnection getConnection() {
    		checkClosed();
    		return conn;
    	}

        private void fillData(PGresult * res, ref Variant[][] data) {
            int rows = PQntuples(res);
            int fieldCount = PQnfields(res);
            int[] fmts = new int[fieldCount];
            int[] types = new int[fieldCount];
            for (int col = 0; col < fieldCount; col++) {
                fmts[col] = PQfformat(res, col);
                types[col] = cast(int)PQftype(res, col);
            }
            for (int row = 0; row < rows; row++) {
                Variant[] v = new Variant[fieldCount];
                for (int col = 0; col < fieldCount; col++) {
                    int n = PQgetisnull(res, row, col);
                    if (n != 0) {
                        v[col] = null;
                    } else {
                        int len = PQgetlength(res, row, col);
                        const ubyte * value = PQgetvalue(res, row, col);
                        int t = types[col];
                        //writeln("[" ~ to!string(row) ~ "][" ~ to!string(col) ~ "] type = " ~ to!string(t) ~ " len = " ~ to!string(len));
                        if (fmts[col] == 0) {
                            // text
                            string s = copyCString(value, len);
                            //writeln("text: " ~ s);
                            switch(t) {
                                case INT4OID:
                                    v[col] = parse!int(s);
                                    break;
                                case BOOLOID:
                                    if( s == "true" || s == "t" || s == "1" )
                                        v[col] = true;
                                    else if( s == "false" || s == "f" || s == "0" )
                                        v[col] = false;
                                    else
                                        v[col] = parse!int(s) != 0;
                                    break;
                                case CHAROID:
                                    v[col] = cast(char)(s.length > 0 ? s[0] : 0);
                                    break;
                                case INT8OID:
                                    v[col] = parse!long(s);
                                    break;
                                case INT2OID:
                                    v[col] = parse!short(s);
                                    break;
                                case FLOAT4OID:
                                    v[col] = parse!float(s);
                                    break;
                                case FLOAT8OID:
                                    v[col] = parse!double(s);
                                    break;
                                case VARCHAROID:
                                case BPCHAROID:
                                case TEXTOID:
                                case NAMEOID:
                                    v[col] = s;
                                    break;
                                case BYTEAOID:
                                    v[col] = byteaToUbytes(s);
                                    break;
                                case TIMESTAMPOID:
                                    //writeln("TIMESTAMPOID: " ~ s);
                                    v[col] = DateTime.fromISOExtString( s.translate( [ ' ': 'T' ] ).split( '.' ).front() );
                                    // todo: use new function in ddbc.utils: parseDateTime(s);
                                    break;
                                case TIMESTAMPTZOID:
                                    //writeln("TIMESTAMPTZOID: " ~ s);
                                    v[col] = SysTime.fromISOExtString( s.translate( [ ' ': 'T' ] ) );
                                    // todo: use new function in ddbc.utils: parseSysTime(s);
                                    break;
                                case TIMEOID:
                                    v[col] = parseTimeoid(s);
                                    break;
                                case DATEOID:
                                    v[col] = parseDateoid(s);
                                    break;
                                case UUIDOID:
                                    v[col] = s;
                                    break;
                                case JSONOID:
                                    v[col] = s;
                                    break;
                                case JSONBOID:
                                    v[col] = s;
                                    break;
                                default:
                                    throw new SQLException("Unsupported column type " ~ to!string(t));
                            }
                        } else {
                            // binary
                            //writeln("binary:");
                            byte[] b = new byte[len];
                            for (int i=0; i<len; i++)
                                b[i] = value[i];
                            v[col] = b;
                        }
                    }
                }
                data ~= v;
            }
        }

    	override ddbc.core.ResultSet executeQuery(string query) {
    		//throw new SQLException("Not implemented");
    		checkClosed();
    		lock();
    		scope(exit) unlock();

            trace(query);

    		PGresult * res = PQexec(conn.getConnection(), std.string.toStringz(query));
    		enforce!SQLException(res !is null, "Failed to execute statement " ~ query);
    		auto status = PQresultStatus(res);
    		enforce!SQLException(status == PGRES_TUPLES_OK, getError());
    		scope(exit) PQclear(res);

    //		cmd = new Command(conn.getConnection(), query);
    //		rs = cmd.execSQLResult();
            auto metadata = createMetadata(res);
            int rows = PQntuples(res);
            int fieldCount = PQnfields(res);
            Variant[][] data;
            fillData(res, data);
            resultSet = new PGSQLResultSet(this, data, metadata);
    		return resultSet;
    	}

    	string getError() {
    		return copyCString(PQerrorMessage(conn.getConnection()));
    	}

    	override int executeUpdate(string query) {
    		Variant dummy;
    		return executeUpdate(query, dummy);
    	}

        void readInsertId(PGresult * res, ref Variant insertId) {
            int rows = PQntuples(res);
            int fieldCount = PQnfields(res);
            //writeln("readInsertId - rows " ~ to!string(rows) ~ " " ~ to!string(fieldCount));
            if (rows == 1 && fieldCount == 1) {
                int len = PQgetlength(res, 0, 0);
                const ubyte * value = PQgetvalue(res, 0, 0);
                string s = copyCString(value, len);
                insertId = parse!long(s);
            }
        }

    	override int executeUpdate(string query, out Variant insertId) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();

            trace(query);

    		PGresult * res = PQexec(conn.getConnection(), std.string.toStringz(query));
    		enforce!SQLException(res !is null, "Failed to execute statement " ~ query);
    		auto status = PQresultStatus(res);
    		enforce!SQLException(status == PGRES_COMMAND_OK || status == PGRES_TUPLES_OK, getError());
    		scope(exit) PQclear(res);

    		string rowsAffected = copyCString(PQcmdTuples(res));

            readInsertId(res, insertId);
//    		auto lastid = PQoidValue(res);
//            writeln("lastId = " ~ to!string(lastid));
            int affected = rowsAffected.length > 0 ? to!int(rowsAffected) : 0;
//    		insertId = Variant(cast(long)lastid);
    		return affected;
    	}

    	override void close() {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		closeResultSet();
    		closed = true;
            conn.onStatementClosed(this);
    	}

    	void closeResultSet() {
    		//throw new SQLException("Not implemented");
    //		if (cmd == null) {
    //			return;
    //		}
    //		cmd.releaseStatement();
    //		delete cmd;
    //		cmd = null;
    //		if (resultSet !is null) {
    //			resultSet.onStatementClosed();
    //			resultSet = null;
    //		}
    	}
    }

    ulong preparedStatementIndex = 1;

    class PGSQLPreparedStatement : PGSQLStatement, PreparedStatement {
    	string query;
    	int paramCount;
    	ResultSetMetaData metadata;
    	ParameterMetaData paramMetadata;
        string stmtName;
        bool[] paramIsSet;
        string[] paramValue;
        //PGresult * rs;

        string convertParams(string query) {
            string res;
            int count = 0;
            bool insideString = false;
            char lastChar = 0;
            foreach(ch; query) {
                if (ch == '\'') {
                    if (insideString) {
                        if (lastChar != '\\')
                            insideString = false;
                    } else {
                        insideString = true;
                    }
                    res ~= ch;
                } else if (ch == '?') {
                    if (!insideString) {
                        count++;
                        res ~= "$" ~ to!string(count);
                    } else {
                        res ~= ch;
                    }
                } else {
                    res ~= ch;
                }
                lastChar = ch;
            }
            paramCount = count;
            return res;
        }

    	this(PGSQLConnection conn, string query) {
    		super(conn);
            query = convertParams(query);
            this.query = query;
            paramMetadata = createParameterMetadata(paramCount);
            stmtName = "ddbcstmt" ~ to!string(preparedStatementIndex);
            paramIsSet = new bool[paramCount];
            paramValue = new string[paramCount];
//            rs = PQprepare(conn.getConnection(),
//                                toStringz(stmtName),
//                                toStringz(query),
//                                paramCount,
//                                null);
//            enforce!SQLException(rs !is null, "Error while preparing statement " ~ query);
//            auto status = PQresultStatus(rs);
            //writeln("prepare paramCount = " ~ to!string(paramCount));
//            enforce!SQLException(status == PGRES_COMMAND_OK || status == PGRES_TUPLES_OK, "Error while preparing statement " ~ query ~ " : " ~ getError(rs));
//            metadata = createMetadata(rs);
            //scope(exit) PQclear(rs);
        }
        string getError(PGresult * res) {
            return copyCString(PQresultErrorMessage(res));
        }
    	void checkIndex(int index) {
    		if (index < 1 || index > paramCount)
    			throw new SQLException("Parameter index " ~ to!string(index) ~ " is out of range");
    	}
        void checkParams() {
            foreach(i, b; paramIsSet)
                enforce!SQLException(b, "Parameter " ~ to!string(i) ~ " is not set");
        }
    	void setParam(int index, string value) {
    		checkIndex(index);
    		paramValue[index - 1] = value;
            paramIsSet[index - 1] = true;
    	}

        PGresult * exec() {
            checkParams();
            const (char) * [] values = new const(char)*[paramCount];
            int[] lengths = new int[paramCount];
            int[] formats = new int[paramCount];
            for (int i=0; i<paramCount; i++) {
                if (paramValue[i] is null)
                    values[i] = null;
                else
                    values[i] = toStringz(paramValue[i]);
                lengths[i] = cast(int)paramValue[i].length;
            }
//            PGresult * res = PQexecPrepared(conn.getConnection(),
//                                            toStringz(stmtName),
//                                            paramCount,
//                                            cast(const char * *)values.ptr,
//                                            cast(const int *)lengths.ptr,
//                                            cast(const int *)formats.ptr,
//                                            0);
            PGresult * res = PQexecParams(conn.getConnection(),
                                 cast(const char *)toStringz(query),
                                 paramCount,
                                 null,
                                 cast(const (ubyte *) *)values.ptr,
                                 cast(const int *)lengths.ptr,
                                 cast(const int *)formats.ptr,
                                 0);
            // Executing a statement will return null for serious errors like being out of memory or
            // being unable to send the query to the server. For other errors, a non-null result is
            // returned, and the status should be looked up.
            // See https://www.postgresql.org/docs/current/libpq-exec.html#LIBPQ-PQEXEC
            enforce!SQLException(res !is null, "Error while executing prepared statement " ~ query);
            enforce!SQLException(
                    PQresultStatus(res) != PGRES_FATAL_ERROR,
                    "Fatal error executing prepared statement " ~ query ~ ": " ~ copyCString(PQresultErrorMessage(res)));
            metadata = createMetadata(res);
            return res;
        }

    public:

		// prepared statements are DialectAware
        override DialectType getDialectType() {
            return conn.getDialectType();
        }

    	/// Retrieves a ResultSetMetaData object that contains information about the columns of the ResultSet object that will be returned when this PreparedStatement object is executed.
    	override ResultSetMetaData getMetaData() {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		return metadata;
    	}

    	/// Retrieves the number, types and properties of this PreparedStatement object's parameters.
    	override ParameterMetaData getParameterMetaData() {
    		//throw new SQLException("Not implemented");
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		return paramMetadata;
    	}

    	override int executeUpdate() {
            Variant dummy;
            return executeUpdate(dummy);
    	}

    	override int executeUpdate(out Variant insertId) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
            PGresult * res = exec();
            scope(exit) PQclear(res);
            auto status = PQresultStatus(res);
            enforce!SQLException(status == PGRES_COMMAND_OK || status == PGRES_TUPLES_OK, getError(res));

            string rowsAffected = copyCString(PQcmdTuples(res));
            //auto lastid = PQoidValue(res);
            readInsertId(res, insertId);
            //writeln("lastId = " ~ to!string(lastid));
            int affected = rowsAffected.length > 0 ? to!int(rowsAffected) : 0;
            //insertId = Variant(cast(long)lastid);
            return affected;
        }

    	override ddbc.core.ResultSet executeQuery() {
    		checkClosed();
    		lock();
    		scope(exit) unlock();

            trace(this.query);

            PGresult * res = exec();
            scope(exit) PQclear(res);
            int rows = PQntuples(res);
            int fieldCount = PQnfields(res);
            Variant[][] data;
            fillData(res, data);
            resultSet = new PGSQLResultSet(this, data, metadata);
            return resultSet;
        }

    	override void clearParameters() {
    		throw new SQLException("Not implemented");
    //		checkClosed();
    //		lock();
    //		scope(exit) unlock();
    //		for (int i = 1; i <= paramCount; i++)
    //			setNull(i);
    	}

    	override void setFloat(int parameterIndex, float x) {
            checkClosed();
            lock();
            scope(exit) unlock();
            setParam(parameterIndex, to!string(x));
        }
    	override void setDouble(int parameterIndex, double x){
            checkClosed();
            lock();
            scope(exit) unlock();
            setParam(parameterIndex, to!string(x));
        }
    	override void setBoolean(int parameterIndex, bool x) {
            checkClosed();
            lock();
            scope(exit) unlock();
            setParam(parameterIndex, x ? "true" : "false");
        }
    	override void setLong(int parameterIndex, long x) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
            setParam(parameterIndex, to!string(x));
    	}

        override void setUlong(int parameterIndex, ulong x) {
            checkClosed();
            lock();
            scope(exit) unlock();
            setParam(parameterIndex, to!string(x));
        }

        override void setInt(int parameterIndex, int x) {
            checkClosed();
            lock();
            scope(exit) unlock();
            setParam(parameterIndex, to!string(x));
        }

        override void setUint(int parameterIndex, uint x) {
            checkClosed();
            lock();
            scope(exit) unlock();
            setParam(parameterIndex, to!string(x));
        }

        override void setShort(int parameterIndex, short x) {
            checkClosed();
            lock();
            scope(exit) unlock();
            setParam(parameterIndex, to!string(x));
        }

        override void setUshort(int parameterIndex, ushort x) {
            checkClosed();
            lock();
            scope(exit) unlock();
            setParam(parameterIndex, to!string(x));
        }

        override void setByte(int parameterIndex, byte x) {
            checkClosed();
            lock();
            scope(exit) unlock();
            setParam(parameterIndex, to!string(x));
        }

        override void setUbyte(int parameterIndex, ubyte x) {
            checkClosed();
            lock();
            scope(exit) unlock();
            checkIndex(parameterIndex);
            setParam(parameterIndex, to!string(x));
        }

        override void setBytes(int parameterIndex, byte[] x) {
            setString(parameterIndex, bytesToBytea(x));
        }
    	override void setUbytes(int parameterIndex, ubyte[] x) {
            setString(parameterIndex, ubytesToBytea(x));
        }
    	override void setString(int parameterIndex, string x) {
            checkClosed();
            lock();
            scope(exit) unlock();
            setParam(parameterIndex, x);
        }
        override void setSysTime(int parameterIndex, SysTime x) {
            setString(parameterIndex, x.toISOString());
        }

    	override void setDateTime(int parameterIndex, DateTime x) {
            setString(parameterIndex, x.toISOString());
        }
    	override void setDate(int parameterIndex, Date x) {
            setString(parameterIndex, x.toISOString());
        }
    	override void setTime(int parameterIndex, TimeOfDay x) {
            setString(parameterIndex, x.toISOString());
        }

    	override void setVariant(int parameterIndex, Variant x) {
            checkClosed();
            lock();
            scope(exit) unlock();
            if (x.convertsTo!DateTime)
                setDateTime(parameterIndex, x.get!DateTime);
            else if (x.convertsTo!Date)
                setDate(parameterIndex, x.get!Date);
            else if (x.convertsTo!TimeOfDay)
                setTime(parameterIndex, x.get!TimeOfDay);
            else if (x.convertsTo!(byte[]))
                setBytes(parameterIndex, x.get!(byte[]));
            else if (x.convertsTo!(ubyte[]))
                setUbytes(parameterIndex, x.get!(ubyte[]));
            else
                setParam(parameterIndex, x.toString());
        }

        override void setNull(int parameterIndex) {
            checkClosed();
            lock();
            scope(exit) unlock();
            setParam(parameterIndex, null);
        }

        override void setNull(int parameterIndex, int sqlType) {
            checkClosed();
            lock();
            scope(exit) unlock();
            setParam(parameterIndex, null);
        }

        override string toString() {
            return this.query;
        }
    }

    class PGSQLResultSet : ResultSetImpl {
    	private PGSQLStatement stmt;
        private Variant[][] data;
    	ResultSetMetaData metadata;
    	private bool closed;
    	private int currentRowIndex;
    	private int rowCount;
    	private int[string] columnMap;
    	private bool lastIsNull;
    	private int columnCount;

    	Variant getValue(int columnIndex) {
    		checkClosed();
    		enforce!SQLException(columnIndex >= 1 && columnIndex <= columnCount, "Column index out of bounds: " ~ to!string(columnIndex));
    		enforce!SQLException(currentRowIndex >= 0 && currentRowIndex < rowCount, "No current row in result set");
    		Variant res = data[currentRowIndex][columnIndex - 1];
            lastIsNull = (res == null);
    		return res;
    	}

    	void checkClosed() {
    		if (closed)
    			throw new SQLException("Result set is already closed");
    	}

    public:

    	void lock() {
    		stmt.lock();
    	}

    	void unlock() {
    		stmt.unlock();
    	}

    	this(PGSQLStatement stmt, Variant[][] data, ResultSetMetaData metadata) {
    		this.stmt = stmt;
    		this.data = data;
    		this.metadata = metadata;
    		closed = false;
    		rowCount = cast(int)data.length;
    		currentRowIndex = -1;
    		columnCount = metadata.getColumnCount();
            for (int i=0; i<columnCount; i++) {
                columnMap[metadata.getColumnName(i + 1)] = i;
            }
            //writeln("created result set: " ~ to!string(rowCount) ~ " rows, " ~ to!string(columnCount) ~ " cols");
        }

    	void onStatementClosed() {
    		closed = true;
    	}

        // ResultSet interface implementation

    	//Retrieves the number, types and properties of this ResultSet object's columns
    	override ResultSetMetaData getMetaData() {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		return metadata;
    	}

    	override void close() {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		stmt.closeResultSet();
    		closed = true;
    	}
    	override bool first() {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		currentRowIndex = 0;
    		return currentRowIndex >= 0 && currentRowIndex < rowCount;
    	}
    	override bool isFirst() {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		return rowCount > 0 && currentRowIndex == 0;
    	}
    	override bool isLast() {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		return rowCount > 0 && currentRowIndex == rowCount - 1;
    	}
    	override bool next() {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		if (currentRowIndex + 1 >= rowCount)
    			return false;
    		currentRowIndex++;
    		return true;
    	}

    	override int findColumn(string columnName) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		int * p = (columnName in columnMap);
    		if (!p)
    			throw new SQLException("Column " ~ columnName ~ " not found");
    		return *p + 1;
    	}

    	override bool getBoolean(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return false;
    		if (v.convertsTo!(bool))
    			return v.get!(bool);
    		if (v.convertsTo!(int))
    			return v.get!(int) != 0;
    		if (v.convertsTo!(long))
    			return v.get!(long) != 0;
    		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to boolean");
    	}
    	override ubyte getUbyte(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return 0;
    		if (v.convertsTo!(ubyte))
    			return v.get!(ubyte);
    		if (v.convertsTo!(long))
    			return to!ubyte(v.get!(long));
    		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to ubyte");
    	}
    	override byte getByte(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return 0;
    		if (v.convertsTo!(byte))
    			return v.get!(byte);
    		if (v.convertsTo!(long))
    			return to!byte(v.get!(long));
    		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to byte");
    	}
    	override short getShort(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return 0;
    		if (v.convertsTo!(short))
    			return v.get!(short);
    		if (v.convertsTo!(long))
    			return to!short(v.get!(long));
    		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to short");
    	}
    	override ushort getUshort(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return 0;
    		if (v.convertsTo!(ushort))
    			return v.get!(ushort);
    		if (v.convertsTo!(long))
    			return to!ushort(v.get!(long));
    		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to ushort");
    	}
    	override int getInt(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return 0;
    		if (v.convertsTo!(int))
    			return v.get!(int);
    		if (v.convertsTo!(long))
    			return to!int(v.get!(long));
    		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to int");
    	}
    	override uint getUint(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return 0;
    		if (v.convertsTo!(uint))
    			return v.get!(uint);
    		if (v.convertsTo!(ulong))
    			return to!uint(v.get!(ulong));
    		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to uint");
    	}
    	override long getLong(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return 0;
    		if (v.convertsTo!(long))
    			return v.get!(long);
    		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to long");
    	}
    	override ulong getUlong(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return 0;
    		if (v.convertsTo!(ulong))
    			return v.get!(ulong);
    		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to ulong");
    	}
    	override double getDouble(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return 0;
    		if (v.convertsTo!(double))
    			return v.get!(double);
    		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to double");
    	}
    	override float getFloat(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return 0;
    		if (v.convertsTo!(float))
    			return v.get!(float);
    		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to float");
    	}
    	override byte[] getBytes(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return null;
    		if (v.convertsTo!(byte[])) {
    			return v.get!(byte[]);
    		}
            return byteaToBytes(v.toString());
    	}
    	override ubyte[] getUbytes(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return null;
    		if (v.convertsTo!(ubyte[])) {
    			return v.get!(ubyte[]);
    		}
            return byteaToUbytes(v.toString());
        }
    	override string getString(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return null;
//    		if (v.convertsTo!(ubyte[])) {
//    			// assume blob encoding is utf-8
//    			// TODO: check field encoding
//    			return decodeTextBlob(v.get!(ubyte[]));
//    		}
    		return v.toString();
    	}

        override SysTime getSysTime(int columnIndex) {
            checkClosed();
            lock();
            scope(exit) unlock();
            Variant v = getValue(columnIndex);
            if (lastIsNull)
                return Clock.currTime();
            if (v.convertsTo!(SysTime)) {
                return v.get!SysTime();
            }
            throw new SQLException("Cannot convert '" ~ v.toString() ~ "' to SysTime");
        }

    	override DateTime getDateTime(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return cast(DateTime) Clock.currTime();
    		if (v.convertsTo!(DateTime)) {
    			return v.get!DateTime();
    		}
    		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to DateTime. '" ~ v.toString() ~ "'");
    	}
    	override Date getDate(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return Date();
    		if (v.convertsTo!(Date)) {
    			return v.get!Date();
    		}
    		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to Date. '" ~ v.toString() ~ "'");
    	}
    	override TimeOfDay getTime(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull)
    			return TimeOfDay();
    		if (v.convertsTo!(TimeOfDay)) {
    			return v.get!TimeOfDay();
    		}
    		throw new SQLException("Cannot convert field " ~ to!string(columnIndex) ~ " to TimeOfDay. '" ~ v.toString() ~ "'");
    	}

    	override Variant getVariant(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		Variant v = getValue(columnIndex);
    		if (lastIsNull) {
    			Variant vnull = null;
    			return vnull;
    		}
    		return v;
    	}
    	override bool wasNull() {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		return lastIsNull;
    	}
    	override bool isNull(int columnIndex) {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		enforce!SQLException(columnIndex >= 1 && columnIndex <= columnCount, "Column index out of bounds: " ~ to!string(columnIndex));
    		enforce!SQLException(currentRowIndex >= 0 && currentRowIndex < rowCount, "No current row in result set");
    		return data[currentRowIndex][columnIndex - 1] == null;
    	}

    	//Retrieves the Statement object that produced this ResultSet object.
    	override Statement getStatement() {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		return stmt;
    	}

    	//Retrieves the current row number
    	override int getRow() {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		if (currentRowIndex <0 || currentRowIndex >= rowCount)
    			return 0;
    		return currentRowIndex + 1;
    	}

    	//Retrieves the fetch size for this ResultSet object.
    	override ulong getFetchSize() {
    		checkClosed();
    		lock();
    		scope(exit) unlock();
    		return rowCount;
    	}
    }


    // sample URL:
    // mysql://localhost:3306/DatabaseName

    //String url = "jdbc:postgresql://localhost/test";
    //Properties props = new Properties();
    //props.setProperty("user","fred");
    //props.setProperty("password","secret");
    //props.setProperty("ssl","true");
    //Connection conn = DriverManager.getConnection(url, props);
    private __gshared static bool _pqIsLoaded = false;
    class PGSQLDriver : Driver {
        this() {
            if (!_pqIsLoaded) {
                DerelictPQ.load();
                _pqIsLoaded = true;
            }
        }
    	// helper function
    	public static string generateUrl(string host = "localhost", ushort port = 5432, string dbname = null) {
    		return "ddbc:postgresql://" ~ host ~ ":" ~ to!string(port) ~ "/" ~ dbname;
    	}
    	public static string[string] setUserAndPassword(string username, string password) {
    		string[string] params;
    		params["user"] = username;
    		params["password"] = password;
    		params["ssl"] = "true";
    		return params;
    	}
    	override ddbc.core.Connection connect(string url, string[string] params) {
            url = stripDdbcPrefix(url);
    		//writeln("PGSQLDriver.connect " ~ url);
    		return new PGSQLConnection(url, params);
    	}
    }

    __gshared static this() {
        // register PGSQLDriver
        import ddbc.common;
        DriverFactory.registerDriverFactory("postgresql", delegate() { return new PGSQLDriver(); });
    }

}
