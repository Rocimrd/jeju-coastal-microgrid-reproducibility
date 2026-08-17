// Annual MILP model for the Jeju coastal microgrid study.
//
// Internal case IDs retained for archived output compatibility.
// C1 = full-coupled planning.
// C2 = feedwater-omitting sizing benchmark.
// C3 = fixed-capacity full-coupled re-evaluation.
//
// Build target: Release x64, C++17, IBM ILOG CPLEX Optimization Studio 22.1.2.
// Single-case use: JejuFullCoupled24h.exe --single input.csv params.json output CASE_ID [capacity.csv]
// RO audit use: JejuFullCoupled24h.exe --audit input.csv params.json output CASE_ID MODE ECON_UB MIP_GAP TIME_LIMIT_S

#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cctype>

#include <algorithm>
#include <cmath>
#include <chrono>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <map>
#include <regex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

#include <ilcplex/ilocplex.h>
ILOSTLBEGIN

struct TimeRow {
    int tau = 0;
    std::string datetime;
    double dt_h = 1.0;
    double omega = 1.0;
    double phi_pv = 0.0;
    double phi_wt = 0.0;
    double p_load_mw = 0.0;
    double w_load_m3_h = 0.0;
    double h2_load_kg_h = 0.0;
    double price_grid_in_usd_kwh = 0.0;
    double price_grid_out_usd_kwh = 0.0;
    double gamma_grid_tco2_mwh = 0.4173;
};

struct Params {
    double discount_rate = 0.035;

    double K_PV_max_MW = 10.0;
    double K_WT_max_MW = 15.0;
    double K_BESS_P_max_MW = 5.0;
    double K_BESS_E_max_MWh = 40.0;
    double K_RO_max_m3_h = 300.0;
    double K_Wtank_max_m3 = 6000.0;
    double K_EL_max_MW = 5.0;
    double K_H2_max_kg = 5000.0;
    double K_FC_max_MW = 3.0;
    double P_DG_max_MW = 2.0;
    double P_grid_import_max_MW = 4.0;
    double P_grid_export_max_MW = 4.0;

    double pv_capex_USD_per_kW = 1560.0;
    double pv_fom_USD_per_kW_yr = 22.0;
    double pv_var_USD_per_MWh = 0.0;
    int pv_lifetime_yr = 30;

    double wt_capex_USD_per_kW = 1349.0;
    double wt_fom_USD_per_kW_yr = 43.0;
    double wt_var_USD_per_MWh = 0.0;
    int wt_lifetime_yr = 30;

    double bess_p_capex_USD_per_kW = 246.0;
    double bess_e_capex_USD_per_kWh = 320.0;
    double bess_fom_fraction = 0.025;
    double bess_var_USD_per_MWh = 0.5;
    int bess_lifetime_yr = 15;
    double eta_b_ch = 0.95;
    double eta_b_dis = 0.95;
    double soc_min = 0.10;
    double soc_max = 0.90;
    double soc_initial = 0.50;
    double duration_min_h = 1.0;
    double duration_max_h = 8.0;

    double ro_SEC_kWh_per_m3 = 4.0;
    double ro_capex_USD_per_m3_h = 36000.0;
    double ro_fom_fraction = 0.03;
    double ro_var_USD_per_m3 = 0.05;
    int ro_lifetime_yr = 25;

    double wtank_capex_USD_per_m3 = 100.0;
    double wtank_fom_fraction = 0.01;
    int wtank_lifetime_yr = 30;
    double water_level_min = 0.10;
    double water_level_max = 1.00;
    double water_level_initial = 0.50;

    double el_kappa_kWh_per_kgH2 = 49.9;
    double el_rho_m3_per_kgH2 = 0.01483;
    double el_capex_USD_per_kW = 1000.0;
    double el_fom_fraction = 0.02;
    int el_lifetime_yr = 20;

    double h2_capex_USD_per_kgH2 = 574.0;
    double h2_fom_fraction = 0.01;
    int h2_lifetime_yr = 25;
    double h2_level_min = 0.05;
    double h2_level_max = 1.00;
    double h2_level_initial = 0.50;

    double fc_capex_USD_per_kW = 1500.0;
    double fc_fom_USD_per_kW_yr = 13.43;
    double fc_var_USD_per_MWh = 0.5125;
    int fc_lifetime_yr = 15;
    double fc_kappa_kWh_per_kgH2 = 16.67;

    double dg_var_USD_per_kWh = 0.30;
    double dg_emission_tCO2_per_MWh = 0.724;
    double freshwater_shortage_penalty_USD_per_m3 = 100.0;
    double hydrogen_shortage_penalty_USD_per_kg = 100.0;
    double carbon_tax_USD_per_tCO2 = 20.0;

    bool carbon_cap_enabled = false;
    double carbon_cap_tCO2 = 1.0e100;
    double carbon_cap_excess_penalty_USD_per_tCO2 = 0.0;
};

struct CapacityFix {
    double K_PV = 0.0;
    double K_WT = 0.0;
    double K_BESS_P = 0.0;
    double K_BESS_E = 0.0;
    double K_RO = 0.0;
    double K_Wtank = 0.0;
    double K_EL = 0.0;
    double K_H2 = 0.0;
    double K_FC = 0.0;
};

static std::vector<std::string> splitCSVLine(const std::string& line) {
    std::vector<std::string> out;
    std::string cur;
    bool inQuotes = false;

    for (size_t i = 0; i < line.size(); ++i) {
        const char c = line[i];
        if (c == '"') {
            if (inQuotes && i + 1 < line.size() && line[i + 1] == '"') {
                cur.push_back('"');
                ++i;
            } else {
                inQuotes = !inQuotes;
            }
        } else if (c == ',' && !inQuotes) {
            out.push_back(cur);
            cur.clear();
        } else {
            cur.push_back(c);
        }
    }
    out.push_back(cur);
    return out;
}

static double toDouble(const std::string& s, double defaultValue = 0.0) {
    if (s.empty()) return defaultValue;
    try {
        return std::stod(s);
    } catch (...) {
        return defaultValue;
    }
}

static std::string readAll(const std::string& path) {
    std::ifstream f(path);
    if (!f.is_open()) {
        throw std::runtime_error("Cannot open file: " + path);
    }
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

static std::string getObject(const std::string& text, const std::string& key) {
    const std::string pattern = "\"" + key + "\"";
    const size_t pos = text.find(pattern);
    if (pos == std::string::npos) return "";

    const size_t start = text.find('{', pos);
    if (start == std::string::npos) return "";

    int depth = 0;
    for (size_t i = start; i < text.size(); ++i) {
        if (text[i] == '{') {
            ++depth;
        } else if (text[i] == '}') {
            --depth;
            if (depth == 0) {
                return text.substr(start, i - start + 1);
            }
        }
    }
    return "";
}

static double getNum(const std::string& obj, const std::string& key, double def) {
    const std::regex r("\"" + key + "\"\\s*:\\s*(-?\\d+(?:\\.\\d+)?(?:[eE][-+]?\\d+)?)");
    std::smatch m;
    if (std::regex_search(obj, m, r)) {
        return std::stod(m[1].str());
    }
    return def;
}

static int getInt(const std::string& obj, const std::string& key, int def) {
    return static_cast<int>(std::round(getNum(obj, key, static_cast<double>(def))));
}

static double crf(double r, int n) {
    if (n <= 0) return 1.0;
    if (std::fabs(r) < 1e-12) return 1.0 / static_cast<double>(n);
    const double a = std::pow(1.0 + r, n);
    return r * a / (a - 1.0);
}

static Params loadParams(const std::string& jsonPath) {
    Params p;
    const std::string j = readAll(jsonPath);

    const std::string finance = getObject(j, "finance");
    p.discount_rate = getNum(finance, "discount_rate", p.discount_rate);

    const std::string b = getObject(j, "capacity_bounds");
    p.K_PV_max_MW = getNum(b, "K_PV_max_MW", p.K_PV_max_MW);
    p.K_WT_max_MW = getNum(b, "K_WT_max_MW", p.K_WT_max_MW);
    p.K_BESS_P_max_MW = getNum(b, "K_BESS_P_max_MW", p.K_BESS_P_max_MW);
    p.K_BESS_E_max_MWh = getNum(b, "K_BESS_E_max_MWh", p.K_BESS_E_max_MWh);
    p.K_RO_max_m3_h = getNum(b, "K_RO_max_m3_h", p.K_RO_max_m3_h);
    p.K_Wtank_max_m3 = getNum(b, "K_Wtank_max_m3", p.K_Wtank_max_m3);
    p.K_EL_max_MW = getNum(b, "K_EL_max_MW", p.K_EL_max_MW);
    p.K_H2_max_kg = getNum(b, "K_H2_max_kg", p.K_H2_max_kg);
    p.K_FC_max_MW = getNum(b, "K_FC_max_MW", p.K_FC_max_MW);
    p.P_DG_max_MW = getNum(b, "P_DG_max_MW", p.P_DG_max_MW);
    p.P_grid_import_max_MW = getNum(b, "P_grid_import_max_MW", p.P_grid_import_max_MW);
    p.P_grid_export_max_MW = getNum(b, "P_grid_export_max_MW", p.P_grid_export_max_MW);

    const std::string pv = getObject(j, "pv");
    p.pv_capex_USD_per_kW = getNum(pv, "capex_USD_per_kW", p.pv_capex_USD_per_kW);
    p.pv_fom_USD_per_kW_yr = getNum(pv, "fixed_om_USD_per_kW_yr", p.pv_fom_USD_per_kW_yr);
    p.pv_var_USD_per_MWh = getNum(pv, "variable_om_USD_per_MWh", p.pv_var_USD_per_MWh);
    p.pv_lifetime_yr = getInt(pv, "lifetime_yr", p.pv_lifetime_yr);

    const std::string w = getObject(j, "wind");
    p.wt_capex_USD_per_kW = getNum(w, "capex_USD_per_kW", p.wt_capex_USD_per_kW);
    p.wt_fom_USD_per_kW_yr = getNum(w, "fixed_om_USD_per_kW_yr", p.wt_fom_USD_per_kW_yr);
    p.wt_var_USD_per_MWh = getNum(w, "variable_om_USD_per_MWh", p.wt_var_USD_per_MWh);
    p.wt_lifetime_yr = getInt(w, "lifetime_yr", p.wt_lifetime_yr);

    const std::string bess = getObject(j, "bess");
    p.bess_p_capex_USD_per_kW = getNum(bess, "power_capex_USD_per_kW", p.bess_p_capex_USD_per_kW);
    p.bess_e_capex_USD_per_kWh = getNum(bess, "energy_capex_USD_per_kWh", p.bess_e_capex_USD_per_kWh);
    p.bess_fom_fraction = getNum(bess, "fixed_om_fraction_of_capex_per_yr", p.bess_fom_fraction);
    p.bess_var_USD_per_MWh = getNum(bess, "variable_om_USD_per_MWh_throughput", p.bess_var_USD_per_MWh);
    p.bess_lifetime_yr = getInt(bess, "lifetime_yr", p.bess_lifetime_yr);
    p.eta_b_ch = getNum(bess, "eta_ch", p.eta_b_ch);
    p.eta_b_dis = getNum(bess, "eta_dis", p.eta_b_dis);
    p.soc_min = getNum(bess, "soc_min", p.soc_min);
    p.soc_max = getNum(bess, "soc_max", p.soc_max);
    p.soc_initial = getNum(bess, "soc_initial", p.soc_initial);
    p.duration_min_h = getNum(bess, "duration_min_h", p.duration_min_h);
    p.duration_max_h = getNum(bess, "duration_max_h", p.duration_max_h);

    const std::string ro = getObject(j, "ro");
    p.ro_SEC_kWh_per_m3 = getNum(ro, "SEC_kWh_per_m3", p.ro_SEC_kWh_per_m3);
    p.ro_capex_USD_per_m3_h = getNum(ro, "capex_USD_per_m3_h", p.ro_capex_USD_per_m3_h);
    p.ro_fom_fraction = getNum(ro, "fixed_om_fraction_of_capex_per_yr", p.ro_fom_fraction);
    p.ro_var_USD_per_m3 = getNum(ro, "variable_om_USD_per_m3", p.ro_var_USD_per_m3);
    p.ro_lifetime_yr = getInt(ro, "lifetime_yr", p.ro_lifetime_yr);

    const std::string wtank = getObject(j, "water_tank");
    p.wtank_capex_USD_per_m3 = getNum(wtank, "capex_USD_per_m3", p.wtank_capex_USD_per_m3);
    p.wtank_fom_fraction = getNum(wtank, "fixed_om_fraction_of_capex_per_yr", p.wtank_fom_fraction);
    p.wtank_lifetime_yr = getInt(wtank, "lifetime_yr", p.wtank_lifetime_yr);
    p.water_level_min = getNum(wtank, "level_min", p.water_level_min);
    p.water_level_max = getNum(wtank, "level_max", p.water_level_max);
    p.water_level_initial = getNum(wtank, "level_initial", p.water_level_initial);

    const std::string el = getObject(j, "electrolyzer");
    p.el_kappa_kWh_per_kgH2 = getNum(el, "kappa_EL_kWh_per_kgH2", p.el_kappa_kWh_per_kgH2);
    p.el_rho_m3_per_kgH2 = getNum(el, "rho_EL_m3_per_kgH2", p.el_rho_m3_per_kgH2);
    p.el_capex_USD_per_kW = getNum(el, "capex_USD_per_kW", p.el_capex_USD_per_kW);
    p.el_fom_fraction = getNum(el, "fixed_om_fraction_of_capex_per_yr", p.el_fom_fraction);
    p.el_lifetime_yr = getInt(el, "lifetime_yr", p.el_lifetime_yr);

    const std::string h2 = getObject(j, "h2_tank");
    p.h2_capex_USD_per_kgH2 = getNum(h2, "capex_USD_per_kgH2", p.h2_capex_USD_per_kgH2);
    p.h2_fom_fraction = getNum(h2, "fixed_om_fraction_of_capex_per_yr", p.h2_fom_fraction);
    p.h2_lifetime_yr = getInt(h2, "lifetime_yr", p.h2_lifetime_yr);
    p.h2_level_min = getNum(h2, "level_min", p.h2_level_min);
    p.h2_level_max = getNum(h2, "level_max", p.h2_level_max);
    p.h2_level_initial = getNum(h2, "level_initial", p.h2_level_initial);

    const std::string fc = getObject(j, "fuel_cell");
    p.fc_capex_USD_per_kW = getNum(fc, "capex_USD_per_kW", p.fc_capex_USD_per_kW);
    p.fc_fom_USD_per_kW_yr = getNum(fc, "fixed_om_USD_per_kW_yr", p.fc_fom_USD_per_kW_yr);
    p.fc_var_USD_per_MWh = getNum(fc, "variable_om_USD_per_MWh", p.fc_var_USD_per_MWh);
    p.fc_lifetime_yr = getInt(fc, "lifetime_yr", p.fc_lifetime_yr);
    p.fc_kappa_kWh_per_kgH2 = getNum(fc, "kappa_FC_kWh_per_kgH2", p.fc_kappa_kWh_per_kgH2);

    const std::string dg = getObject(j, "diesel");
    p.dg_var_USD_per_kWh = getNum(dg, "variable_cost_USD_per_kWh", p.dg_var_USD_per_kWh);
    p.dg_emission_tCO2_per_MWh = getNum(dg, "emission_factor_tCO2_per_MWh", p.dg_emission_tCO2_per_MWh);

    const std::string pol = getObject(j, "shortage_and_policy");
    p.freshwater_shortage_penalty_USD_per_m3 = getNum(pol, "freshwater_shortage_penalty_USD_per_m3", p.freshwater_shortage_penalty_USD_per_m3);
    p.hydrogen_shortage_penalty_USD_per_kg = getNum(pol, "hydrogen_shortage_penalty_USD_per_kg", p.hydrogen_shortage_penalty_USD_per_kg);
    p.carbon_tax_USD_per_tCO2 = getNum(pol, "carbon_tax_base_USD_per_tCO2", p.carbon_tax_USD_per_tCO2);

    return p;
}

static std::vector<TimeRow> loadTimeSeries(const std::string& path) {
    std::ifstream fin(path);
    if (!fin.is_open()) {
        throw std::runtime_error("Cannot open CSV file: " + path);
    }

    std::string headerLine;
    std::getline(fin, headerLine);
    std::vector<std::string> headers = splitCSVLine(headerLine);

    std::map<std::string, int> col;
    for (int i = 0; i < static_cast<int>(headers.size()); ++i) {
        col[headers[i]] = i;
    }

    auto get = [&](const std::vector<std::string>& row, const std::string& name, double def = 0.0) {
        const auto it = col.find(name);
        if (it == col.end() || it->second >= static_cast<int>(row.size())) return def;
        return toDouble(row[it->second], def);
    };

    auto gets = [&](const std::vector<std::string>& row, const std::string& name) {
        const auto it = col.find(name);
        if (it == col.end() || it->second >= static_cast<int>(row.size())) return std::string();
        return row[it->second];
    };

    std::vector<TimeRow> data;
    std::string line;
    while (std::getline(fin, line)) {
        if (line.empty()) continue;
        const std::vector<std::string> row = splitCSVLine(line);
        TimeRow x;
        x.tau = static_cast<int>(get(row, "tau", static_cast<double>(data.size() + 1)));
        x.datetime = gets(row, "datetime");
        x.dt_h = get(row, "delta_t_h", 1.0);
        x.omega = get(row, "omega", 1.0);
        x.phi_pv = get(row, "phi_pv", 0.0);
        x.phi_wt = get(row, "phi_wt", 0.0);
        x.p_load_mw = get(row, "P_load_MG_MW", 0.0);
        x.w_load_m3_h = get(row, "W_load_adj_m3_h", get(row, "W_load_base_m3_h", 0.0));
        x.h2_load_kg_h = get(row, "H2_load_adj_kg_h", get(row, "H2_load_base_kg_h", 0.0));
        x.price_grid_in_usd_kwh = get(row, "price_grid_in_USD_kWh", 0.0);
        x.price_grid_out_usd_kwh = get(row, "price_grid_out_USD_kWh", 0.0);
        x.gamma_grid_tco2_mwh = get(row, "gamma_grid_tCO2eq_MWh", 0.4173);
        data.push_back(x);
    }

    if (data.empty()) {
        throw std::runtime_error("No rows loaded from time-series file: " + path);
    }
    return data;
}

static CapacityFix loadCapacityFix(const std::string& path) {
    CapacityFix k;
    std::ifstream fin(path);
    if (!fin.is_open()) {
        throw std::runtime_error("Cannot open capacity file for fixed-capacity re-evaluation: " + path);
    }

    std::string header;
    std::getline(fin, header);

    std::string line;
    while (std::getline(fin, line)) {
        if (line.empty()) continue;
        std::vector<std::string> row = splitCSVLine(line);
        if (row.size() < 2) continue;

        const std::string name = row[0];
        const double val = toDouble(row[1], 0.0);

        if (name == "K_PV") k.K_PV = val;
        else if (name == "K_WT") k.K_WT = val;
        else if (name == "K_BESS_P") k.K_BESS_P = val;
        else if (name == "K_BESS_E") k.K_BESS_E = val;
        else if (name == "K_RO") k.K_RO = val;
        else if (name == "K_Wtank") k.K_Wtank = val;
        else if (name == "K_EL") k.K_EL = val;
        else if (name == "K_H2") k.K_H2 = val;
        else if (name == "K_FC") k.K_FC = val;
    }

    return k;
}

static void ensureOutputDir(const std::string& dir) {
#ifdef _WIN32
    const std::string cmd = "if not exist \"" + dir + "\" mkdir \"" + dir + "\"";
#else
    const std::string cmd = "mkdir -p \"" + dir + "\"";
#endif
    std::system(cmd.c_str());
}

static bool containsText(const std::string& s, const std::string& key) {
    return s.find(key) != std::string::npos;
}

static bool extractNumberAfterKey(const std::string& s, const std::string& key, double& value) {
    const std::size_t pos = s.find(key);
    if (pos == std::string::npos) return false;
    std::size_t i = pos + key.size();
    if (i >= s.size() || !std::isdigit(static_cast<unsigned char>(s[i]))) return false;
    std::size_t j = i;
    while (j < s.size() && (std::isdigit(static_cast<unsigned char>(s[j])) || s[j] == '.')) {
        ++j;
    }
    try {
        value = std::stod(s.substr(i, j - i));
        return true;
    } catch (...) {
        return false;
    }
}


enum class AuditMode {
    None,
    BaseEconomic,
    MinRO,
    MaxRO
};

static const char* auditModeName(AuditMode mode) {
    switch (mode) {
    case AuditMode::BaseEconomic: return "BASE";
    case AuditMode::MinRO: return "MINRO";
    case AuditMode::MaxRO: return "MAXRO";
    default: return "NONE";
    }
}

static AuditMode parseAuditMode(const std::string& s) {
    if (s == "BASE") return AuditMode::BaseEconomic;
    if (s == "MINRO") return AuditMode::MinRO;
    if (s == "MAXRO") return AuditMode::MaxRO;
    throw std::runtime_error("Unknown audit mode: " + s);
}

static int runModel(const std::string& tsPathInput,
                    const std::string& paramPathInput,
                    const std::string& outDirInput,
                    const std::string& caseIdInput,
                    const std::string& capFixPathInput,
                    AuditMode auditMode = AuditMode::None,
                    double nearOptEconomicUB = -1.0,
                    double solverMipGap = 1.0e-4,
                    double solverTimeLimitSec = 3600.0) {
    std::string tsPath = tsPathInput;
    std::string paramPath = paramPathInput;
    std::string outDir = outDirInput;
    std::string caseId = caseIdInput;
    std::string capFixPath = capFixPathInput;

    const bool isC3 = containsText(caseId, "C3");
    const bool isC2 = containsText(caseId, "C2");
    const bool isStress = containsText(caseId, "STRESS");
    const bool hardService = containsText(caseId, "HARDSERVICE");
    const bool decoupledWaterBalance = isC2 && !isC3;

    if (hardService && !isC3) {
        std::cerr << "HARDSERVICE is only valid for fixed-capacity C3 re-evaluation." << std::endl;
        return 4;
    }

    const bool nearOptRangeMode = (auditMode == AuditMode::MinRO || auditMode == AuditMode::MaxRO);
    if (auditMode != AuditMode::None && isC3) {
        std::cerr << "Near-optimal RO audit is defined only for C1/C2 planning formulations." << std::endl;
        return 4;
    }
    if (nearOptRangeMode && (!(nearOptEconomicUB > 0.0) || !std::isfinite(nearOptEconomicUB))) {
        std::cerr << "Near-optimal RO audit requires a positive finite economic-objective upper bound." << std::endl;
        return 4;
    }
    if (!(solverMipGap > 0.0) || !(solverTimeLimitSec > 0.0)) {
        std::cerr << "Invalid solver audit settings." << std::endl;
        return 4;
    }

    if (isC3 && capFixPath.empty()) {
        if (isStress) {
            capFixPath = outDir + "/capacity_decoupled_C2_C2_STRESS_7DAY.csv";
        } else {
            capFixPath = outDir + "/capacity_decoupled_C2_C2_7DAY.csv";
        }
    }

    try {
        ensureOutputDir(outDir);

        Params p = loadParams(paramPath);
        std::vector<TimeRow> ts = loadTimeSeries(tsPath);

        // Apply case settings after reading the common input files.
        const bool isC4NoWaterTank = containsText(caseId, "C4") || containsText(caseId, "NOWTANK");
        const bool isC5NoH2Tank    = containsText(caseId, "C5") || containsText(caseId, "NOH2TANK");
        const bool isC6NoFC        = containsText(caseId, "C6") || containsText(caseId, "NOFC");
        const bool isC7NoBess      = containsText(caseId, "C7") || containsText(caseId, "NOBESS");
        const bool isNoHessSubsystem = containsText(caseId, "NOHESS_SUBSYSTEM");
        const bool isC7NoCarbon    = containsText(caseId, "NOCARBON");
        const bool isC8HighTax     = containsText(caseId, "C8") || containsText(caseId, "TAX100");
        const bool isC9CarbonCap   = containsText(caseId, "C9") || containsText(caseId, "CARBONCAP") || containsText(caseId, "CO2CAP");
        const bool isC10Water130   = containsText(caseId, "C10") || containsText(caseId, "WATER130");
        const bool isC11ROSEC125   = containsText(caseId, "C11") || containsText(caseId, "ROSEC125");
        const bool isC12LowEL115   = containsText(caseId, "C12") || containsText(caseId, "LOWEL115");

        double explicitTax = 0.0;
        const bool hasExplicitTax = extractNumberAfterKey(caseId, "TAX", explicitTax);
        double explicitWaterPercent = 0.0;
        const bool hasExplicitWater = extractNumberAfterKey(caseId, "WATER", explicitWaterPercent);
        double explicitH2DemandKgDay = 0.0;
        const bool hasExplicitH2Demand = extractNumberAfterKey(caseId, "H2D", explicitH2DemandKgDay);
        double explicitROSECPercent = 0.0;
        const bool hasExplicitROSEC = extractNumberAfterKey(caseId, "ROSEC", explicitROSECPercent);
        double explicitELPercent = 0.0;
        const bool hasExplicitEL = extractNumberAfterKey(caseId, "EL", explicitELPercent);
        double explicitBessCostPercent = 0.0;
        const bool hasExplicitBessCost = extractNumberAfterKey(caseId, "BESSCOST", explicitBessCostPercent);
        double explicitHessCostPercent = 0.0;
        const bool hasExplicitHessCost = extractNumberAfterKey(caseId, "HESSCOST", explicitHessCostPercent);
        double explicitElCostPercent = 0.0;
        const bool hasExplicitElCost = extractNumberAfterKey(caseId, "ELCOST", explicitElCostPercent);
        double explicitH2CostPercent = 0.0;
        const bool hasExplicitH2Cost = extractNumberAfterKey(caseId, "H2COST", explicitH2CostPercent);
        double explicitFcCostPercent = 0.0;
        const bool hasExplicitFcCost = extractNumberAfterKey(caseId, "FCCOST", explicitFcCostPercent);
        double explicitBessDurMax = 0.0;
        const bool hasExplicitBessDurMax = extractNumberAfterKey(caseId, "BESSDURMAX", explicitBessDurMax);
        double explicitBessDurMin = 0.0;
        const bool hasExplicitBessDurMin = extractNumberAfterKey(caseId, "BESSDURMIN", explicitBessDurMin);
        double explicitGridCap = 0.0;
        const bool hasExplicitGridCap = extractNumberAfterKey(caseId, "GRIDCAP", explicitGridCap);

        // Optional capacity limits used in sensitivity runs.
        double explicitH2UbKg = 0.0;
        const bool hasExplicitH2Ub = extractNumberAfterKey(caseId, "H2UB", explicitH2UbKg);
        double explicitElUbMW = 0.0;
        const bool hasExplicitElUb = extractNumberAfterKey(caseId, "ELUB", explicitElUbMW);
        double explicitFcUbMW = 0.0;
        const bool hasExplicitFcUb = extractNumberAfterKey(caseId, "FCUB", explicitFcUbMW);
        double explicitPvUbMW = 0.0;
        const bool hasExplicitPvUb = extractNumberAfterKey(caseId, "PVUB", explicitPvUbMW);
        double explicitWtUbMW = 0.0;
        const bool hasExplicitWtUb = extractNumberAfterKey(caseId, "WTUB", explicitWtUbMW);

        double explicitTariffSpreadPercent = 0.0;
        const bool hasExplicitTariffSpread = extractNumberAfterKey(caseId, "SPREAD", explicitTariffSpreadPercent);
        double explicitBuyPercent = 0.0;
        const bool hasExplicitBuy = extractNumberAfterKey(caseId, "BUY", explicitBuyPercent);
        double explicitSellPercent = 0.0;
        const bool hasExplicitSellPercent = extractNumberAfterKey(caseId, "SELL", explicitSellPercent);
        const bool sellAsSMP = containsText(caseId, "SELLSMP") || containsText(caseId, "EXPORTSMP");

        double waterDemandMultiplier = 1.0;
        double h2DemandMultiplier = 1.0;
        double roSecMultiplier = 1.0;
        double elKappaMultiplier = 1.0;

        if (isC7NoCarbon) {
            p.carbon_tax_USD_per_tCO2 = 0.0;
        }
        if (isC8HighTax) {
            p.carbon_tax_USD_per_tCO2 = 100.0;
        }
        if (hasExplicitTax) {
            p.carbon_tax_USD_per_tCO2 = explicitTax;
        }
        if (isC9CarbonCap) {
            p.carbon_tax_USD_per_tCO2 = 0.0;
            p.carbon_cap_enabled = true;
            p.carbon_cap_tCO2 = 6000.0;
            p.carbon_cap_excess_penalty_USD_per_tCO2 = 250.0;
        }
        if (isC10Water130) {
            waterDemandMultiplier = 1.30;
        }
        if (hasExplicitWater) {
            waterDemandMultiplier = explicitWaterPercent / 100.0;
        }
        if (hasExplicitH2Demand) {
            // Scale the H2 profile to the requested daily average.
            h2DemandMultiplier = explicitH2DemandKgDay / 1000.0;
        }
        if (isC11ROSEC125) {
            roSecMultiplier = 1.25;
        }
        if (hasExplicitROSEC) {
            roSecMultiplier = explicitROSECPercent / 100.0;
        }
        if (isC12LowEL115) {
            elKappaMultiplier = 1.15;
        }
        if (hasExplicitEL) {
            elKappaMultiplier = explicitELPercent / 100.0;
        }
        if (hasExplicitBessCost) {
            const double m = explicitBessCostPercent / 100.0;
            p.bess_p_capex_USD_per_kW *= m;
            p.bess_e_capex_USD_per_kWh *= m;
        }
        if (hasExplicitHessCost) {
            const double m = explicitHessCostPercent / 100.0;
            p.el_capex_USD_per_kW *= m;
            p.h2_capex_USD_per_kgH2 *= m;
            p.fc_capex_USD_per_kW *= m;
        }
        if (hasExplicitElCost) {
            p.el_capex_USD_per_kW *= explicitElCostPercent / 100.0;
        }
        if (hasExplicitH2Cost) {
            p.h2_capex_USD_per_kgH2 *= explicitH2CostPercent / 100.0;
        }
        if (hasExplicitFcCost) {
            p.fc_capex_USD_per_kW *= explicitFcCostPercent / 100.0;
        }
        if (hasExplicitBessDurMax) {
            p.duration_max_h = std::max(p.duration_min_h, explicitBessDurMax);
        }
        if (hasExplicitBessDurMin) {
            p.duration_min_h = std::max(0.0, explicitBessDurMin);
            p.duration_max_h = std::max(p.duration_min_h, p.duration_max_h);
        }
        if (containsText(caseId, "NOEXPORT")) {
            p.P_grid_export_max_MW = 0.0;
        }
        if (hasExplicitGridCap) {
            p.P_grid_import_max_MW = explicitGridCap;
            p.P_grid_export_max_MW = explicitGridCap;
        }
        if (hasExplicitH2Ub) {
            p.K_H2_max_kg = std::max(0.0, explicitH2UbKg);
        }
        if (hasExplicitElUb) {
            p.K_EL_max_MW = std::max(0.0, explicitElUbMW);
        }
        if (hasExplicitFcUb) {
            p.K_FC_max_MW = std::max(0.0, explicitFcUbMW);
        }
        if (hasExplicitPvUb) {
            p.K_PV_max_MW = std::max(0.0, explicitPvUbMW);
        }
        if (hasExplicitWtUb) {
            p.K_WT_max_MW = std::max(0.0, explicitWtUbMW);
        }

        if (std::abs(waterDemandMultiplier - 1.0) > 1.0e-12) {
            for (TimeRow& r : ts) {
                r.w_load_m3_h *= waterDemandMultiplier;
            }
        }
        if (std::abs(h2DemandMultiplier - 1.0) > 1.0e-12) {
            for (TimeRow& r : ts) {
                r.h2_load_kg_h *= h2DemandMultiplier;
            }
        }
        // Scale the grid purchase price when requested by the case ID.
        if (hasExplicitBuy) {
            const double buyMultiplier = explicitBuyPercent / 100.0;
            for (TimeRow& r : ts) {
                r.price_grid_in_usd_kwh = std::max(0.0, buyMultiplier * r.price_grid_in_usd_kwh);
            }
        }
        if (hasExplicitTariffSpread) {
            const double spreadMultiplier = explicitTariffSpreadPercent / 100.0;
            double weightedSum = 0.0;
            double weightDen = 0.0;
            for (const TimeRow& r : ts) {
                const double w = std::max(0.0, r.omega * r.dt_h);
                weightedSum += w * r.price_grid_in_usd_kwh;
                weightDen += w;
            }
            const double meanPrice = (weightDen > 0.0) ? (weightedSum / weightDen) : 0.0;
            for (TimeRow& r : ts) {
                r.price_grid_in_usd_kwh = std::max(0.0, meanPrice + spreadMultiplier * (r.price_grid_in_usd_kwh - meanPrice));
            }
        }
        // Set the export-price rule from the case ID.
        if (sellAsSMP || hasExplicitSellPercent) {
            const double sellMultiplier = sellAsSMP ? 1.0 : (explicitSellPercent / 100.0);
            for (TimeRow& r : ts) {
                r.price_grid_out_usd_kwh = sellMultiplier * r.price_grid_in_usd_kwh;
            }
        }
        p.ro_SEC_kWh_per_m3 *= roSecMultiplier;
        p.el_kappa_kWh_per_kgH2 *= elKappaMultiplier;

        const int T = static_cast<int>(ts.size());

        CapacityFix fix;
        if (isC3) {
            fix = loadCapacityFix(capFixPath);
        }

        double horizonHours = 0.0;
        double weightedHours = 0.0;
        for (const TimeRow& r : ts) {
            horizonHours += r.dt_h;
            weightedHours += r.omega * r.dt_h;
        }
        const double capitalScale = weightedHours / 8760.0;

        IloEnv env;
        try {
            IloModel model(env);

            double pv_lb = 0.0, pv_ub = p.K_PV_max_MW;
            double wt_lb = 0.0, wt_ub = p.K_WT_max_MW;
            double bp_lb = 0.0, bp_ub = p.K_BESS_P_max_MW;
            double be_lb = 0.0, be_ub = p.K_BESS_E_max_MWh;
            double ro_lb = 0.0, ro_ub = p.K_RO_max_m3_h;
            double w_lb = 0.0, w_ub = p.K_Wtank_max_m3;
            double el_lb = 0.0, el_ub = p.K_EL_max_MW;
            double h_lb = 0.0, h_ub = p.K_H2_max_kg;
            double fc_lb = 0.0, fc_ub = p.K_FC_max_MW;

            if (isC3) {
                pv_lb = pv_ub = fix.K_PV;
                wt_lb = wt_ub = fix.K_WT;
                bp_lb = bp_ub = fix.K_BESS_P;
                be_lb = be_ub = fix.K_BESS_E;
                ro_lb = ro_ub = fix.K_RO;
                w_lb = w_ub = fix.K_Wtank;
                el_lb = el_ub = fix.K_EL;
                h_lb = h_ub = fix.K_H2;
                fc_lb = fc_ub = fix.K_FC;
            } else {
                if (isC4NoWaterTank) {
                    w_lb = w_ub = 0.0;
                }
                if (isC5NoH2Tank) {
                    h_lb = h_ub = 0.0;
                }
                if (isC6NoFC) {
                    fc_lb = fc_ub = 0.0;
                }
                if (isNoHessSubsystem) {
                    el_lb = el_ub = 0.0;
                    h_lb = h_ub = 0.0;
                    fc_lb = fc_ub = 0.0;
                }
                if (isC7NoBess) {
                    bp_lb = bp_ub = 0.0;
                    be_lb = be_ub = 0.0;
                }
            }

            IloNumVar K_PV(env, pv_lb, pv_ub, ILOFLOAT, "K_PV_MW");
            IloNumVar K_WT(env, wt_lb, wt_ub, ILOFLOAT, "K_WT_MW");
            IloNumVar K_BP(env, bp_lb, bp_ub, ILOFLOAT, "K_BESS_P_MW");
            IloNumVar K_BE(env, be_lb, be_ub, ILOFLOAT, "K_BESS_E_MWh");
            IloNumVar K_RO(env, ro_lb, ro_ub, ILOFLOAT, "K_RO_m3_h");
            IloNumVar K_W(env, w_lb, w_ub, ILOFLOAT, "K_Wtank_m3");
            IloNumVar K_EL(env, el_lb, el_ub, ILOFLOAT, "K_EL_MW");
            IloNumVar K_H(env, h_lb, h_ub, ILOFLOAT, "K_H2_kg");
            IloNumVar K_FC(env, fc_lb, fc_ub, ILOFLOAT, "K_FC_MW");

            model.add(K_BE >= p.duration_min_h * K_BP);
            model.add(K_BE <= p.duration_max_h * K_BP);

            if (isStress && isC2 && !isC3) {
                model.add(K_BP >= 0.50);
                model.add(K_BE >= 2.00);
                model.add(K_EL >= 0.80);
                model.add(K_H >= 300.0);
                model.add(K_FC >= 0.60);
            }

            IloNumVarArray Ppv(env, T, 0.0, IloInfinity, ILOFLOAT);
            IloNumVarArray PpvCur(env, T, 0.0, IloInfinity, ILOFLOAT);
            IloNumVarArray Pwt(env, T, 0.0, IloInfinity, ILOFLOAT);
            IloNumVarArray PwtCur(env, T, 0.0, IloInfinity, ILOFLOAT);
            IloNumVarArray PDG(env, T, 0.0, p.P_DG_max_MW, ILOFLOAT);
            IloNumVarArray Pgin(env, T, 0.0, p.P_grid_import_max_MW, ILOFLOAT);
            IloNumVarArray Pgout(env, T, 0.0, p.P_grid_export_max_MW, ILOFLOAT);
            IloNumVarArray PBch(env, T, 0.0, p.K_BESS_P_max_MW, ILOFLOAT);
            IloNumVarArray PBdis(env, T, 0.0, p.K_BESS_P_max_MW, ILOFLOAT);
            IloNumVarArray EB(env, T, 0.0, p.K_BESS_E_max_MWh, ILOFLOAT);
            IloNumVarArray PRO(env, T, 0.0, IloInfinity, ILOFLOAT);
            IloNumVarArray WRO(env, T, 0.0, p.K_RO_max_m3_h, ILOFLOAT);
            IloNumVarArray SW(env, T, 0.0, p.K_Wtank_max_m3, ILOFLOAT);
            IloNumVarArray Wsh(env, T, 0.0, IloInfinity, ILOFLOAT);
            IloNumVarArray PEL(env, T, 0.0, p.K_EL_max_MW, ILOFLOAT);
            IloNumVarArray HEL(env, T, 0.0, IloInfinity, ILOFLOAT);
            IloNumVarArray WEL(env, T, 0.0, IloInfinity, ILOFLOAT);
            IloNumVarArray PFC(env, T, 0.0, p.K_FC_max_MW, ILOFLOAT);
            IloNumVarArray HFC(env, T, 0.0, IloInfinity, ILOFLOAT);
            IloNumVarArray Hserv(env, T, 0.0, IloInfinity, ILOFLOAT);
            IloNumVarArray Hsh(env, T, 0.0, IloInfinity, ILOFLOAT);
            IloNumVarArray SH(env, T, 0.0, p.K_H2_max_kg, ILOFLOAT);

            IloBoolVarArray uGrid(env, T);
            IloBoolVarArray uBess(env, T);
            IloBoolVarArray uHess(env, T);

            IloExpr totalBch(env);
            IloExpr totalBdis(env);
            IloExpr totalHEL(env);
            IloExpr totalHFC(env);
            IloExpr totalHserv(env);
            IloExpr totalHsh(env);
            IloExpr totalWEL(env);

            for (int t = 0; t < T; ++t) {
                const double dt = ts[t].dt_h;
                const double Pload = ts[t].p_load_mw;
                const double Wload = ts[t].w_load_m3_h;
                const double Hload = ts[t].h2_load_kg_h;

                model.add(Ppv[t] + PpvCur[t] == ts[t].phi_pv * K_PV);
                model.add(Pwt[t] + PwtCur[t] == ts[t].phi_wt * K_WT);

                model.add(Pgin[t] <= p.P_grid_import_max_MW * uGrid[t]);
                model.add(Pgout[t] <= p.P_grid_export_max_MW * (1 - uGrid[t]));

                model.add(PBch[t] <= K_BP);
                model.add(PBdis[t] <= K_BP);
                model.add(PBch[t] <= p.K_BESS_P_max_MW * uBess[t]);
                model.add(PBdis[t] <= p.K_BESS_P_max_MW * (1 - uBess[t]));
                model.add(EB[t] >= p.soc_min * K_BE);
                model.add(EB[t] <= p.soc_max * K_BE);

                model.add(PRO[t] == (p.ro_SEC_kWh_per_m3 / 1000.0) * WRO[t]);
                model.add(WRO[t] <= K_RO);
                model.add(Wsh[t] <= Wload);
                model.add(SW[t] >= p.water_level_min * K_W);
                model.add(SW[t] <= p.water_level_max * K_W);

                model.add(PEL[t] == (p.el_kappa_kWh_per_kgH2 / 1000.0) * HEL[t]);
                model.add(WEL[t] == p.el_rho_m3_per_kgH2 * HEL[t]);
                model.add(PFC[t] == (p.fc_kappa_kWh_per_kgH2 / 1000.0) * HFC[t]);
                model.add(Hserv[t] + Hsh[t] == Hload);
                model.add(Hsh[t] <= Hload);

                if (hardService) {
                    model.add(Wsh[t] == 0.0);
                    model.add(Hsh[t] == 0.0);
                }

                model.add(PEL[t] <= K_EL);
                model.add(PFC[t] <= K_FC);
                model.add(PEL[t] <= p.K_EL_max_MW * uHess[t]);
                model.add(PFC[t] <= p.K_FC_max_MW * (1 - uHess[t]));

                model.add(SH[t] >= p.h2_level_min * K_H);
                model.add(SH[t] <= p.h2_level_max * K_H);

                model.add(Ppv[t] + Pwt[t] + PDG[t] + Pgin[t] + PBdis[t] + PFC[t]
                    == Pload + PBch[t] + PRO[t] + PEL[t] + Pgout[t]);

                if (t == 0) {
                    model.add(EB[t] - p.soc_initial * K_BE
                        == (p.eta_b_ch * PBch[t] - PBdis[t] / p.eta_b_dis) * dt);

                    if (decoupledWaterBalance) {
                        model.add(SW[t] - p.water_level_initial * K_W
                            == (WRO[t] - (Wload - Wsh[t])) * dt);
                    } else {
                        model.add(SW[t] - p.water_level_initial * K_W
                            == (WRO[t] - (Wload - Wsh[t]) - WEL[t]) * dt);
                    }

                    model.add(SH[t] - p.h2_level_initial * K_H
                        == (HEL[t] - HFC[t] - Hserv[t]) * dt);
                } else {
                    model.add(EB[t] - EB[t - 1]
                        == (p.eta_b_ch * PBch[t] - PBdis[t] / p.eta_b_dis) * dt);

                    if (decoupledWaterBalance) {
                        model.add(SW[t] - SW[t - 1]
                            == (WRO[t] - (Wload - Wsh[t])) * dt);
                    } else {
                        model.add(SW[t] - SW[t - 1]
                            == (WRO[t] - (Wload - Wsh[t]) - WEL[t]) * dt);
                    }

                    model.add(SH[t] - SH[t - 1]
                        == (HEL[t] - HFC[t] - Hserv[t]) * dt);
                }

                totalBch += PBch[t] * dt;
                totalBdis += PBdis[t] * dt;
                totalHEL += HEL[t] * dt;
                totalHFC += HFC[t] * dt;
                totalHserv += Hserv[t] * dt;
                totalHsh += Hsh[t] * dt;
                totalWEL += WEL[t] * dt;
            }

            model.add(EB[T - 1] == p.soc_initial * K_BE);
            model.add(SW[T - 1] == p.water_level_initial * K_W);
            model.add(SH[T - 1] == p.h2_level_initial * K_H);

            if (isStress && isC2 && !isC3) {
                model.add(totalBch >= 0.75);
                model.add(totalBdis >= 0.50);
                model.add(totalHEL >= 200.0);
                model.add(totalHFC >= 200.0);
                model.add(totalWEL >= 2.5);
            }

            totalBch.end();
            totalBdis.end();
            totalHEL.end();
            totalHFC.end();
            totalHserv.end();
            totalHsh.end();
            totalWEL.end();

            IloNumVar EcapExcess(env, 0.0, IloInfinity, ILOFLOAT, "Ecap_excess_tCO2");
            IloExpr annualCO2expr(env);
            IloExpr economicObj(env);

            economicObj += capitalScale * (crf(p.discount_rate, p.pv_lifetime_yr) * p.pv_capex_USD_per_kW + p.pv_fom_USD_per_kW_yr) * 1000.0 * K_PV;
            economicObj += capitalScale * (crf(p.discount_rate, p.wt_lifetime_yr) * p.wt_capex_USD_per_kW + p.wt_fom_USD_per_kW_yr) * 1000.0 * K_WT;

            economicObj += capitalScale * (crf(p.discount_rate, p.bess_lifetime_yr) * p.bess_p_capex_USD_per_kW + p.bess_fom_fraction * p.bess_p_capex_USD_per_kW) * 1000.0 * K_BP;
            economicObj += capitalScale * (crf(p.discount_rate, p.bess_lifetime_yr) * p.bess_e_capex_USD_per_kWh + p.bess_fom_fraction * p.bess_e_capex_USD_per_kWh) * 1000.0 * K_BE;

            economicObj += capitalScale * (crf(p.discount_rate, p.ro_lifetime_yr) * p.ro_capex_USD_per_m3_h + p.ro_fom_fraction * p.ro_capex_USD_per_m3_h) * K_RO;
            economicObj += capitalScale * (crf(p.discount_rate, p.wtank_lifetime_yr) * p.wtank_capex_USD_per_m3 + p.wtank_fom_fraction * p.wtank_capex_USD_per_m3) * K_W;

            economicObj += capitalScale * (crf(p.discount_rate, p.el_lifetime_yr) * p.el_capex_USD_per_kW + p.el_fom_fraction * p.el_capex_USD_per_kW) * 1000.0 * K_EL;
            economicObj += capitalScale * (crf(p.discount_rate, p.h2_lifetime_yr) * p.h2_capex_USD_per_kgH2 + p.h2_fom_fraction * p.h2_capex_USD_per_kgH2) * K_H;
            economicObj += capitalScale * (crf(p.discount_rate, p.fc_lifetime_yr) * p.fc_capex_USD_per_kW + p.fc_fom_USD_per_kW_yr) * 1000.0 * K_FC;

            for (int t = 0; t < T; ++t) {
                const double dt = ts[t].dt_h;
                const double w = ts[t].omega;

                economicObj += w * dt * 1000.0 * ts[t].price_grid_in_usd_kwh * Pgin[t];
                economicObj -= w * dt * 1000.0 * ts[t].price_grid_out_usd_kwh * Pgout[t];

                economicObj += w * dt * 1000.0 * p.dg_var_USD_per_kWh * PDG[t];
                economicObj += w * dt * p.pv_var_USD_per_MWh * Ppv[t];
                economicObj += w * dt * p.wt_var_USD_per_MWh * Pwt[t];
                economicObj += w * dt * p.bess_var_USD_per_MWh * (PBch[t] + PBdis[t]);
                economicObj += w * dt * p.ro_var_USD_per_m3 * WRO[t];
                economicObj += w * dt * p.fc_var_USD_per_MWh * PFC[t];

                annualCO2expr += w * dt * (ts[t].gamma_grid_tco2_mwh * Pgin[t] + p.dg_emission_tCO2_per_MWh * PDG[t]);

                economicObj += w * dt * p.carbon_tax_USD_per_tCO2
                    * (ts[t].gamma_grid_tco2_mwh * Pgin[t] + p.dg_emission_tCO2_per_MWh * PDG[t]);

                economicObj += w * dt * p.freshwater_shortage_penalty_USD_per_m3 * Wsh[t];
                economicObj += w * dt * p.hydrogen_shortage_penalty_USD_per_kg * Hsh[t];
            }

            if (p.carbon_cap_enabled) {
                model.add(EcapExcess >= annualCO2expr - p.carbon_cap_tCO2);
                model.add(EcapExcess >= 0.0);
                economicObj += p.carbon_cap_excess_penalty_USD_per_tCO2 * EcapExcess;
            } else {
                model.add(EcapExcess == 0.0);
            }

            if (auditMode == AuditMode::MinRO) {
                model.add(economicObj <= nearOptEconomicUB);
                model.add(IloMinimize(env, K_RO));
            } else if (auditMode == AuditMode::MaxRO) {
                model.add(economicObj <= nearOptEconomicUB);
                model.add(IloMaximize(env, K_RO));
            } else {
                model.add(IloMinimize(env, economicObj));
            }
            annualCO2expr.end();

            IloCplex cplex(model);
            cplex.setParam(IloCplex::Param::MIP::Tolerances::MIPGap, solverMipGap);
            cplex.setParam(IloCplex::Param::TimeLimit, solverTimeLimitSec);
            cplex.setOut(env.getNullStream());

            std::cout << "Solving model..." << std::endl;
            std::cout << "Internal case ID = " << caseId << std::endl;
            std::cout << "Mode = ";
            if (isC3) std::cout << "Fixed-capacity full-coupled re-evaluation";
            else if (isC2) std::cout << "Feedwater-omitting sizing benchmark";
            else std::cout << "Full-coupled planning";
            std::cout << std::endl;
            std::cout << "Decoupled water balance = " << (decoupledWaterBalance ? "yes" : "no") << std::endl;
            std::cout << "Rows = " << T << ", horizon hours = " << horizonHours
                      << ", weighted hours = " << weightedHours
                      << ", capital scale = " << capitalScale << std::endl;
            std::cout << "Scenario modifiers: noWTank=" << (isC4NoWaterTank ? "yes" : "no")
                      << ", noH2Tank=" << (isC5NoH2Tank ? "yes" : "no")
                      << ", noFC=" << (isC6NoFC ? "yes" : "no")
                      << ", noBESS=" << (isC7NoBess ? "yes" : "no")
                      << ", carbon_tax=" << p.carbon_tax_USD_per_tCO2
                      << ", carbon_cap=" << (p.carbon_cap_enabled ? "yes" : "no")
                      << ", RO_SEC=" << p.ro_SEC_kWh_per_m3
                      << ", EL_kappa=" << p.el_kappa_kWh_per_kgH2
                      << ", H2_shortage_penalty=" << p.hydrogen_shortage_penalty_USD_per_kg << std::endl;
            if (isStress) std::cout << "Stress constraints are active during feedwater-omitting sizing. The re-evaluation only fixes the resulting capacities." << std::endl;
            if (hardService) std::cout << "Hard-service feasibility mode = yes (freshwater shortage = 0, H2 shortage = 0)" << std::endl;
            if (isC3) std::cout << "Capacity fix file = " << capFixPath << std::endl;
            if (auditMode != AuditMode::None) {
                std::cout << "RO audit mode = " << auditModeName(auditMode) << std::endl;
                std::cout << "Solver MIP gap target = " << solverMipGap << std::endl;
                std::cout << "Solver time limit = " << solverTimeLimitSec << " s" << std::endl;
                if (nearOptRangeMode) {
                    std::cout << "Economic objective upper bound = " << std::setprecision(15)
                              << nearOptEconomicUB << " USD/yr" << std::endl;
                }
            }

            const auto solveWallStart = std::chrono::steady_clock::now();
            const bool ok = cplex.solve();
            const auto solveWallEnd = std::chrono::steady_clock::now();
            const double solveWallSeconds =
                std::chrono::duration<double>(solveWallEnd - solveWallStart).count();

            std::string prefix;
            if (isC3) prefix = "expost_C3";
            else if (isC2) prefix = "decoupled_C2";
            else if (containsText(caseId, "C1")) prefix = "full_coupled_C1";
            else prefix = "full_coupled";
            const std::string summaryPath = outDir + "/summary_" + prefix + "_" + caseId + ".csv";
            const std::string capPath = outDir + "/capacity_" + prefix + "_" + caseId + ".csv";
            const std::string dispPath = outDir + "/dispatch_" + prefix + "_" + caseId + ".csv";

            std::ofstream summary(summaryPath);
            if (!summary.is_open()) {
                std::cerr << "Cannot create summary output file: " << summaryPath << std::endl;
                std::cerr << "Use a shorter output path." << std::endl;
                env.end();
                return 3;
            }
            summary << "metric,value\n";
            summary << "status," << cplex.getStatus() << "\n";
            summary << "hard_service_mode," << (hardService ? 1 : 0) << "\n";
            summary << "audit_mode," << auditModeName(auditMode) << "\n";
            summary << "solver_mip_gap_target," << std::setprecision(15) << solverMipGap << "\n";
            summary << "solver_time_limit_s," << solverTimeLimitSec << "\n";
            summary << "solve_wall_time_s," << solveWallSeconds << "\n";
            if (nearOptRangeMode) {
                summary << "economic_objective_upper_bound_USD," << nearOptEconomicUB << "\n";
            } else {
                summary << "economic_objective_upper_bound_USD,NaN\n";
            }

            if (!ok) {
                summary << "objective_USD,NaN\n";
                summary << "economic_objective_USD,NaN\n";
                summary << "audit_objective_value,NaN\n";
                summary << "best_bound,NaN\n";
                summary << "achieved_relative_mip_gap,NaN\n";
                summary.close();
                std::cerr << "No feasible/optimal solution. CPLEX status: " << cplex.getStatus() << std::endl;
                env.end();
                return 2;
            }

            const double auditObjectiveValue = cplex.getObjValue();
            const double economicObjectiveValue = cplex.getValue(economicObj);
            const double bestBoundValue = cplex.getBestObjValue();
            const double achievedRelativeGap = cplex.getMIPRelativeGap();

            std::ofstream cap(capPath);
            if (!cap.is_open()) {
                std::cerr << "Cannot create capacity output file: " << capPath << std::endl;
                summary.close();
                env.end();
                return 3;
            }
            cap << std::setprecision(15);
            cap << "capacity,value,unit\n";
            cap << "K_PV," << cplex.getValue(K_PV) << ",MW\n";
            cap << "K_WT," << cplex.getValue(K_WT) << ",MW\n";
            cap << "K_BESS_P," << cplex.getValue(K_BP) << ",MW\n";
            cap << "K_BESS_E," << cplex.getValue(K_BE) << ",MWh\n";
            cap << "K_RO," << cplex.getValue(K_RO) << ",m3/h\n";
            cap << "K_Wtank," << cplex.getValue(K_W) << ",m3\n";
            cap << "K_EL," << cplex.getValue(K_EL) << ",MW\n";
            cap << "K_H2," << cplex.getValue(K_H) << ",kg-H2\n";
            cap << "K_FC," << cplex.getValue(K_FC) << ",MW\n";
            cap.close();

            double gridMWh = 0.0;
            double exportMWh = 0.0;
            double gridBuyCostUSD = 0.0;
            double gridSellRevenueUSD = 0.0;
            double weightedBuyPriceSum = 0.0;
            double weightedSellPriceSum = 0.0;
            double weightedPriceDen = 0.0;
            double dgMWh = 0.0;
            double pvMWh = 0.0;
            double wtMWh = 0.0;
            double curtMWh = 0.0;
            double roM3 = 0.0;
            double wshM3 = 0.0;
            double elKg = 0.0;
            double fcKg = 0.0;
            double h2LoadKg = 0.0;
            double h2ServedKg = 0.0;
            double h2ShortageKg = 0.0;
            double welM3 = 0.0;
            double co2t = 0.0;

            const bool writeDispatch = (auditMode == AuditMode::None);
            std::ofstream disp;
            if (writeDispatch) {
                disp.open(dispPath);
                if (!disp.is_open()) {
                    std::cerr << "Cannot create dispatch output file: " << dispPath << std::endl;
                    summary.close();
                    env.end();
                    return 3;
                }
                disp << std::setprecision(15);
                disp << "t,datetime,P_load_MW,W_load_m3_h,H2_load_kg_h,phi_pv,phi_wt,"
                     << "Ppv_MW,Ppv_cur_MW,Pwt_MW,Pwt_cur_MW,PDG_MW,Pgin_MW,Pgout_MW,"
                     << "PBch_MW,PBdis_MW,EB_MWh,PRO_MW,WRO_m3_h,SW_m3,Wsh_m3_h,"
                     << "PEL_MW,HEL_kg_h,WEL_m3_h,PFC_MW,HFC_kg_h,H2_served_kg_h,H2_shortage_kg_h,SH_kg\n";
            }

            for (int t = 0; t < T; ++t) {
                const double dt = ts[t].dt_h;
                const double vPpv = cplex.getValue(Ppv[t]);
                const double vPpvCur = cplex.getValue(PpvCur[t]);
                const double vPwt = cplex.getValue(Pwt[t]);
                const double vPwtCur = cplex.getValue(PwtCur[t]);
                const double vPDG = cplex.getValue(PDG[t]);
                const double vPgin = cplex.getValue(Pgin[t]);
                const double vPgout = cplex.getValue(Pgout[t]);
                const double vWRO = cplex.getValue(WRO[t]);
                const double vWsh = cplex.getValue(Wsh[t]);
                const double vHEL = cplex.getValue(HEL[t]);
                const double vHFC = cplex.getValue(HFC[t]);
                const double vHserv = cplex.getValue(Hserv[t]);
                const double vHsh = cplex.getValue(Hsh[t]);
                const double vWEL = cplex.getValue(WEL[t]);

                const double wd = ts[t].omega * dt;
                gridMWh += vPgin * wd;
                exportMWh += vPgout * wd;
                gridBuyCostUSD += 1000.0 * ts[t].price_grid_in_usd_kwh * vPgin * wd;
                gridSellRevenueUSD += 1000.0 * ts[t].price_grid_out_usd_kwh * vPgout * wd;
                weightedBuyPriceSum += ts[t].price_grid_in_usd_kwh * wd;
                weightedSellPriceSum += ts[t].price_grid_out_usd_kwh * wd;
                weightedPriceDen += wd;
                dgMWh += vPDG * wd;
                pvMWh += vPpv * wd;
                wtMWh += vPwt * wd;
                curtMWh += (vPpvCur + vPwtCur) * wd;
                roM3 += vWRO * wd;
                wshM3 += vWsh * wd;
                elKg += vHEL * wd;
                fcKg += vHFC * wd;
                h2LoadKg += ts[t].h2_load_kg_h * wd;
                h2ServedKg += vHserv * wd;
                h2ShortageKg += vHsh * wd;
                welM3 += vWEL * wd;
                co2t += (ts[t].gamma_grid_tco2_mwh * vPgin + p.dg_emission_tCO2_per_MWh * vPDG) * wd;

                if (writeDispatch) {
                    disp << t + 1 << "," << ts[t].datetime << ","
                         << ts[t].p_load_mw << "," << ts[t].w_load_m3_h << "," << ts[t].h2_load_kg_h << ","
                         << ts[t].phi_pv << "," << ts[t].phi_wt << ","
                         << vPpv << "," << vPpvCur << "," << vPwt << "," << vPwtCur << ","
                         << vPDG << "," << vPgin << "," << vPgout << ","
                         << cplex.getValue(PBch[t]) << "," << cplex.getValue(PBdis[t]) << "," << cplex.getValue(EB[t]) << ","
                         << cplex.getValue(PRO[t]) << "," << vWRO << "," << cplex.getValue(SW[t]) << "," << vWsh << ","
                         << cplex.getValue(PEL[t]) << "," << vHEL << "," << vWEL << ","
                         << cplex.getValue(PFC[t]) << "," << vHFC << "," << vHserv << "," << vHsh << "," << cplex.getValue(SH[t]) << "\n";
                }
            }
            if (writeDispatch) disp.close();

            summary << std::setprecision(15);
            summary << "objective_USD," << economicObjectiveValue << "\n";
            summary << "economic_objective_USD," << economicObjectiveValue << "\n";
            summary << "audit_objective_value," << auditObjectiveValue << "\n";
            summary << "best_bound," << bestBoundValue << "\n";
            summary << "achieved_relative_mip_gap," << achievedRelativeGap << "\n";
            summary << "horizon_hours," << horizonHours << "\n";
            summary << "capital_scale," << capitalScale << "\n";
            summary << "decoupled_water_balance," << (decoupledWaterBalance ? 1 : 0) << "\n";
            summary << "fixed_capacity_mode," << (isC3 ? 1 : 0) << "\n";
            summary << "stress_mode," << (isStress ? 1 : 0) << "\n";
            summary << "grid_import_cap_MW," << p.P_grid_import_max_MW << "\n";
            summary << "grid_export_cap_MW," << p.P_grid_export_max_MW << "\n";
            summary << "carbon_tax_USD_per_tCO2," << p.carbon_tax_USD_per_tCO2 << "\n";
            summary << "avg_grid_buy_price_USD_kWh," << ((weightedPriceDen > 0.0) ? (weightedBuyPriceSum / weightedPriceDen) : 0.0) << "\n";
            summary << "avg_grid_sell_price_USD_kWh," << ((weightedPriceDen > 0.0) ? (weightedSellPriceSum / weightedPriceDen) : 0.0) << "\n";
            summary << "total_grid_import_MWh," << gridMWh << "\n";
            summary << "total_grid_export_MWh," << exportMWh << "\n";
            summary << "total_grid_purchase_cost_USD," << gridBuyCostUSD << "\n";
            summary << "total_grid_export_revenue_USD," << gridSellRevenueUSD << "\n";
            summary << "net_grid_cost_USD," << (gridBuyCostUSD - gridSellRevenueUSD) << "\n";
            summary << "total_diesel_MWh," << dgMWh << "\n";
            summary << "total_PV_MWh," << pvMWh << "\n";
            summary << "total_WT_MWh," << wtMWh << "\n";
            summary << "total_RE_curtailment_MWh," << curtMWh << "\n";
            summary << "total_RO_water_m3," << roM3 << "\n";
            summary << "total_freshwater_shortage_m3," << wshM3 << "\n";
            summary << "total_H2_produced_kg," << elKg << "\n";
            summary << "total_H2_consumed_by_FC_kg," << fcKg << "\n";
            summary << "total_H2_external_load_kg," << h2LoadKg << "\n";
            summary << "total_H2_served_kg," << h2ServedKg << "\n";
            summary << "total_H2_shortage_kg," << h2ShortageKg << "\n";
            summary << "H2_shortage_ratio," << ((h2LoadKg > 0.0) ? (h2ShortageKg / h2LoadKg) : 0.0) << "\n";
            summary << "total_EL_feedwater_m3," << welM3 << "\n";
            summary << "EL_feedwater_to_community_water_ratio," << ((roM3 > 0.0) ? (welM3 / std::max(1.0e-12, roM3 - welM3)) : 0.0) << "\n";
            summary << "total_CO2_t," << co2t << "\n";
            summary.close();

            std::cout << "Solved. Economic objective = " << std::setprecision(15)
                      << economicObjectiveValue << " USD/yr" << std::endl;
            if (auditMode == AuditMode::MinRO || auditMode == AuditMode::MaxRO) {
                std::cout << "RO capacity audit objective = " << auditObjectiveValue << " m3/h" << std::endl;
            }
            std::cout << "Best bound = " << bestBoundValue
                      << ", achieved relative MIP gap = " << achievedRelativeGap
                      << ", solve wall time = " << solveWallSeconds << " s" << std::endl;
            std::cout << "Capacity file: " << capPath << std::endl;
            if (writeDispatch) std::cout << "Dispatch file: " << dispPath << std::endl;
            std::cout << "Summary file: " << summaryPath << std::endl;

            env.end();
            return 0;
        } catch (IloException& e) {
            std::cerr << "CPLEX/Concert exception: " << e << std::endl;
            env.end();
            return 1;
        } catch (...) {
            std::cerr << "Unknown exception inside CPLEX environment." << std::endl;
            env.end();
            return 1;
        }
    } catch (const std::exception& e) {
        std::cerr << "Fatal error: " << e.what() << std::endl;
        return 1;
    }
}

int main(int argc, char* argv[]) {
    // Default annual case set. The last four cases remove the water tank, H2 tank, fuel cell, or BESS.

    const std::string defaultTs = "input/timeseries_2025_final_refined_coastal_h2hub_v21_2.csv";
    const std::string defaultParam = "input/base_params_final_refined_coastal_h2hub_v21_2.json";
    const std::string defaultOut = "output_8760_final_v21_2_c1_c7";

    // Near-optimal RO-capacity audit:
    //   exe --audit input.csv params.json out_dir CASE_ID BASE 0 MIP_GAP TIME_LIMIT_S
    //   exe --audit input.csv params.json out_dir CASE_ID MINRO ECONOMIC_UB MIP_GAP TIME_LIMIT_S
    //   exe --audit input.csv params.json out_dir CASE_ID MAXRO ECONOMIC_UB MIP_GAP TIME_LIMIT_S
    if (argc >= 10 && std::string(argv[1]) == "--audit") {
        const std::string tsPath = argv[2];
        const std::string paramPath = argv[3];
        const std::string outDir = argv[4];
        const std::string caseId = argv[5];
        const AuditMode mode = parseAuditMode(argv[6]);
        const double economicUB = std::stod(argv[7]);
        const double mipGap = std::stod(argv[8]);
        const double timeLimitSec = std::stod(argv[9]);
        return runModel(tsPath, paramPath, outDir, caseId, "", mode, economicUB, mipGap, timeLimitSec);
    }

    // Run one standard case from the command line.
    if (argc >= 6 && std::string(argv[1]) == "--single") {
        const std::string tsPath = argv[2];
        const std::string paramPath = argv[3];
        const std::string outDir = argv[4];
        const std::string caseId = argv[5];
        const std::string capFixPath = (argc >= 7) ? argv[6] : "";
        return runModel(tsPath, paramPath, outDir, caseId, capFixPath);
    }

    std::string tsPath = defaultTs;
    std::string paramPath = defaultParam;
    std::string outDir = defaultOut;

    if (argc >= 2) tsPath = argv[1];
    if (argc >= 3) paramPath = argv[2];
    if (argc >= 4) outDir = argv[3];

    ensureOutputDir(outDir);

    struct RunItem {
        std::string caseId;
        std::string capFixPath;
    };

    auto c2CapPath = [&](const std::string& c2CaseId) -> std::string {
        return outDir + "/capacity_decoupled_C2_" + c2CaseId + ".csv";
    };

    const std::string baseToken = "V21_2_SC01_E5_W2000_H2D1000_RELAXED_GRIDCAP1.5_TAX150_SELL80_H2D1000_8760";
    const std::string c1 = "C1_FULL_" + baseToken;
    const std::string c2 = "C2_DECOUPLED_" + baseToken;
    const std::string c3 = "C3_EXPOST_" + baseToken;
    const std::string c4 = "C4_NOWTANK_" + baseToken;
    const std::string c5 = "C5_NOH2TANK_" + baseToken;
    const std::string c6 = "C6_NOFC_" + baseToken;
    const std::string c7 = "C7_NOBESS_" + baseToken;

    std::vector<RunItem> runs;
    runs.push_back({c1, ""});
    runs.push_back({c2, ""});
    runs.push_back({c3, c2CapPath(c2)});
    runs.push_back({c4, ""});
    runs.push_back({c5, ""});
    runs.push_back({c6, ""});
    runs.push_back({c7, ""});

    const std::string manifestPath = outDir + "/run_manifest_8760_final_v21_2_c1_c7.csv";
    std::ofstream manifest(manifestPath);
    manifest << "caseId,return_code,summary_file,capacity_file,dispatch_file\n";

    std::cout << "Running annual model case set." << std::endl;
    std::cout << "Input time series = " << tsPath << std::endl;
    std::cout << "Parameter file = " << paramPath << std::endl;
    std::cout << "Output directory = " << outDir << std::endl;
    std::cout << "Cases = full-coupled planning, feedwater-omitting sizing, fixed-capacity re-evaluation, no water tank, no H2 tank, no fuel cell, no BESS" << std::endl;

    for (size_t i = 0; i < runs.size(); ++i) {
        const std::string& caseId = runs[i].caseId;
        std::string prefix;
        if (containsText(caseId, "C3")) prefix = "expost_C3";
        else if (containsText(caseId, "C2")) prefix = "decoupled_C2";
        else if (containsText(caseId, "C1")) prefix = "full_coupled_C1";
        else prefix = "full_coupled";

        const std::string expectedSummary = outDir + "/summary_" + prefix + "_" + caseId + ".csv";
        const std::string expectedCapacity = outDir + "/capacity_" + prefix + "_" + caseId + ".csv";
        const std::string expectedDispatch = outDir + "/dispatch_" + prefix + "_" + caseId + ".csv";

        std::cout << "\n=== Case step " << (i + 1) << "/" << runs.size() << " ===" << std::endl;
        std::cout << "Internal case ID = " << caseId << std::endl;
        int rc = runModel(tsPath, paramPath, outDir, caseId, runs[i].capFixPath);
        manifest << caseId << "," << rc << "," << expectedSummary << "," << expectedCapacity << "," << expectedDispatch << "\n";
        manifest.flush();
        if (rc != 0) {
            std::cerr << "Stopping sequence because case failed: " << caseId << " return code " << rc << std::endl;
            return rc;
        }
    }

    std::cout << "Annual model case set finished." << std::endl;
    std::cout << "Manifest: " << manifestPath << std::endl;
    return 0;
}
