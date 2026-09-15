import { Route, Routes } from "react-router-dom";
import { Shell } from "./components/Shell";
import Home from "./pages/Home";
import Join from "./pages/Join";
import Members from "./pages/Members";
import Verify from "./pages/Verify";
import Admin from "./pages/Admin";

export default function App() {
  return (
    <Shell>
      <Routes>
        <Route path="/" element={<Home />} />
        <Route path="/join" element={<Join />} />
        <Route path="/members" element={<Members />} />
        <Route path="/verify" element={<Verify />} />
        <Route path="/admin" element={<Admin />} />
      </Routes>
    </Shell>
  );
}
